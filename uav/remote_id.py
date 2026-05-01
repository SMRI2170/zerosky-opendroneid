#!/usr/bin/env python3
"""UAV OpenDroneID (ASTM F3411-22a) BLE broadcaster for Raspberry Pi.

エンコード仕様は opendroneid-core-c に完全準拠:
  https://github.com/opendroneid/opendroneid-core-c

BLE Service UUID 0xFFFA の Service Data AD として BasicID と Location を
1秒ごとに交互にブロードキャストする。

使い方:
  # GPS + BME280 センサーから取得（デフォルト）
  python3 uav/remote_id.py --gps

  # GPS ポートを明示指定
  python3 uav/remote_id.py --gps --gps-port /dev/ttyUSB0

  # 固定座標
  python3 uav/remote_id.py --lat 35.6891390 --lon 139.6917000 --alt 12.0

依存ライブラリ（GPS+BME280 モード時）:
  pip install pyserial pynmea2 smbus2 RPi.bme280
"""

import argparse
import json
import math
import struct
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path

# ── HCI 設定 ──────────────────────────────────────────────────────────────────
HCI_DEV = "hci0"

# ── opendroneid-core-c 定数 ───────────────────────────────────────────────────
ODID_MESSAGE_SIZE    = 25
ODID_ID_SIZE         = 20
ODID_PROTOCOL_VERSION = 2
ODID_SERVICE_UUID    = 0xFFFA

# ODID_messagetype_t
ODID_MESSAGETYPE_BASIC_ID  = 0
ODID_MESSAGETYPE_LOCATION  = 1
ODID_MESSAGETYPE_AUTH      = 2
ODID_MESSAGETYPE_SELF_ID   = 3
ODID_MESSAGETYPE_SYSTEM    = 4
ODID_MESSAGETYPE_OPERATOR_ID = 5
ODID_MESSAGETYPE_PACKED    = 0xF

# ODID_idtype_t
ODID_IDTYPE_NONE              = 0
ODID_IDTYPE_SERIAL_NUMBER     = 1
ODID_IDTYPE_CAA_REGISTRATION  = 2
ODID_IDTYPE_UTM_ASSIGNED_UUID = 3
ODID_IDTYPE_SPECIFIC_SESSION  = 4

# ODID_uatype_t
ODID_UATYPE_NONE                     = 0
ODID_UATYPE_AEROPLANE                = 1
ODID_UATYPE_HELICOPTER_OR_MULTIROTOR = 2
ODID_UATYPE_GYROPLANE                = 3
ODID_UATYPE_HYBRID_LIFT              = 4

# ODID_status_t  ← core-c: UNDECLARED=0 GROUND=1 AIRBORNE=2 EMERGENCY=3
ODID_STATUS_UNDECLARED             = 0
ODID_STATUS_GROUND                 = 1
ODID_STATUS_AIRBORNE               = 2
ODID_STATUS_EMERGENCY              = 3
ODID_STATUS_REMOTE_ID_SYSTEM_FAILURE = 4

# ODID_Height_reference_t
ODID_HEIGHT_REF_OVER_TAKEOFF = 0
ODID_HEIGHT_REF_OVER_GROUND  = 1

# エンコード係数 (core-c と同一)
_LATLON_MULT  = 10_000_000   # int32 = lat_deg * 1e7
_ALT_DIV      = 0.5          # uint16 unit = 0.5 m
_ALT_ADDER    = 1000         # offset -1000 m
_SPEED_DIV    = [0.25, 0.75] # m/s per LSB (low/high speed multiplier)
_VSPEED_DIV   = 0.5          # m/s per LSB (int8)
_TS_DIV       = 0.1          # seconds per LSB

# GPS ポート自動検出候補
_GPS_PORT_CANDIDATES = [
    "/dev/ttyACM0",
    "/dev/ttyUSB0",
    "/dev/ttyAMA0",
    "/dev/serial0",
]

_BME280_ADDR_DEFAULT = 0x76


# ── データモデル ───────────────────────────────────────────────────────────────

@dataclass
class TelemetrySample:
    latitude:        float
    longitude:       float
    altitude_geo_m:  float   # GPS 高度 (WGS84)
    altitude_baro_m: float   # 気圧高度 (QFE 基準)
    unix_time_sec:   int


class TelemetryProvider:
    def read(self) -> TelemetrySample:
        raise NotImplementedError


# ── 静的・JSON プロバイダー ────────────────────────────────────────────────────

class StaticTelemetryProvider(TelemetryProvider):
    def __init__(self, latitude: float, longitude: float, altitude_m: float):
        self.latitude   = latitude
        self.longitude  = longitude
        self.altitude_m = altitude_m

    def read(self) -> TelemetrySample:
        return TelemetrySample(
            latitude=self.latitude,
            longitude=self.longitude,
            altitude_geo_m=self.altitude_m,
            altitude_baro_m=self.altitude_m,
            unix_time_sec=int(time.time()),
        )


class JsonTelemetryProvider(TelemetryProvider):
    def __init__(self, path: str):
        self.path = Path(path)

    def read(self) -> TelemetrySample:
        payload = json.loads(self.path.read_text())
        alt = float(payload.get("altitude_m", 0.0))
        return TelemetrySample(
            latitude=float(payload["latitude"]),
            longitude=float(payload["longitude"]),
            altitude_geo_m=alt,
            altitude_baro_m=float(payload.get("altitude_baro_m", alt)),
            unix_time_sec=int(payload.get("unix_time_sec", time.time())),
        )


# ── GPS + BME280 プロバイダー ─────────────────────────────────────────────────

def _detect_gps_port() -> str:
    import serial
    for port in _GPS_PORT_CANDIDATES:
        try:
            s = serial.Serial(port, baudrate=9600, timeout=0.5)
            s.close()
            return port
        except Exception:
            continue
    raise RuntimeError(
        f"GPS ポートが見つかりません。候補: {_GPS_PORT_CANDIDATES}\n"
        "--gps-port で明示指定してください。"
    )


class GpsBme280TelemetryProvider(TelemetryProvider):
    """GPS（シリアル NMEA）+ BME280（I2C）で QFE 高度を計算する。"""

    def __init__(self, gps_port: str, bme280_addr: int = _BME280_ADDR_DEFAULT):
        import serial
        self._serial = serial.Serial(gps_port, baudrate=9600, timeout=1)
        print(f"GPS: {gps_port} を開きました")

        self._bme280        = None
        self._bme280_lib    = None
        self._bme280_bus    = None
        self._bme280_addr   = bme280_addr
        self._bme280_params = None
        self._ground_pressure_hpa: float | None = None
        try:
            import smbus2
            import bme280 as bme280_lib
            bus    = smbus2.SMBus(1)
            params = bme280_lib.load_calibration_params(bus, bme280_addr)
            self._bme280_lib    = bme280_lib
            self._bme280_bus    = bus
            self._bme280_params = params
            self._bme280        = True
            first = bme280_lib.sample(bus, bme280_addr, params)
            self._ground_pressure_hpa = first.pressure
            print(f"BME280: I2C 0x{bme280_addr:02X} 地上気圧={first.pressure:.1f}hPa")
        except Exception as e:
            print(f"BME280 利用不可 → GPS 高度を使用します ({e})")

        self._lock:   threading.Lock         = threading.Lock()
        self._latest: TelemetrySample | None = None
        t = threading.Thread(target=self._gps_reader_loop, daemon=True)
        t.start()

    def _gps_reader_loop(self) -> None:
        import pynmea2
        last_alt_geo = 0.0
        while True:
            try:
                line = self._serial.readline().decode("ascii", errors="replace").strip()
                if not line.startswith("$"):
                    continue
                msg = pynmea2.parse(line)
                lat, lon, alt_geo = self._extract_fix(msg)
                if lat is None:
                    continue
                if alt_geo > 0.0:
                    last_alt_geo = alt_geo
                else:
                    alt_geo = last_alt_geo
                alt_baro = self._read_baro_altitude(fallback=alt_geo)
                sample = TelemetrySample(
                    latitude=lat,
                    longitude=lon,
                    altitude_geo_m=alt_geo,
                    altitude_baro_m=alt_baro,
                    unix_time_sec=int(time.time()),
                )
                with self._lock:
                    self._latest = sample
            except Exception:
                time.sleep(0.05)

    @staticmethod
    def _extract_fix(msg) -> tuple:
        try:
            s = msg.sentence_type
            if s == "GGA":
                if int(msg.gps_qual or 0) == 0:
                    return None, None, 0.0
                lat, lon = msg.latitude, msg.longitude
                if lat == 0.0 and lon == 0.0:
                    return None, None, 0.0
                return lat, lon, float(msg.altitude or 0.0)
            if s == "RMC":
                if msg.status != "A":
                    return None, None, 0.0
                return msg.latitude, msg.longitude, 0.0
        except Exception:
            pass
        return None, None, 0.0

    def _read_baro_altitude(self, fallback: float) -> float:
        if not self._bme280 or self._ground_pressure_hpa is None:
            return fallback
        try:
            d = self._bme280_lib.sample(self._bme280_bus, self._bme280_addr, self._bme280_params)
            return round(44330.0 * (1.0 - (d.pressure / self._ground_pressure_hpa) ** (1.0 / 5.255)), 2)
        except Exception:
            return fallback

    def read(self) -> TelemetrySample:
        with self._lock:
            if self._latest is not None:
                return self._latest
        return TelemetrySample(
            latitude=0.0, longitude=0.0,
            altitude_geo_m=0.0,
            altitude_baro_m=self._read_baro_altitude(fallback=0.0),
            unix_time_sec=int(time.time()),
        )


# ── opendroneid-core-c 準拠エンコード ─────────────────────────────────────────

def _encode_altitude(alt_m: float) -> int:
    """(alt_m + 1000) / 0.5 → uint16。0xFFFF = 不明。"""
    if alt_m <= -1000:
        return 0xFFFF
    raw = round((alt_m + _ALT_ADDER) / _ALT_DIV)
    return max(0, min(0xFFFE, raw))


def _encode_direction(direction_deg: float) -> tuple[int, int]:
    """方向を EWDirection フラグ + uint8 にエンコード。"""
    if direction_deg < 0 or direction_deg > 360:
        return 0, 0
    if direction_deg >= 180.0:
        return 1, round(direction_deg - 180.0)
    return 0, round(direction_deg)


def _encode_speed_h(speed_ms: float) -> tuple[int, int]:
    """水平速度を SpeedMult フラグ + uint8 にエンコード (core-c SPEED_DIV)。"""
    if speed_ms < 0 or speed_ms > 254.25:
        return 0, 0
    if speed_ms <= 63.75:
        return 0, round(speed_ms / _SPEED_DIV[0])
    return 1, round((speed_ms - 63.75) / _SPEED_DIV[1])


def _encode_speed_v(speed_ms: float) -> int:
    """垂直速度 int8 にエンコード (core-c VSPEED_DIV=0.5)。"""
    clamped = max(-62.0, min(62.0, speed_ms))
    return round(clamped / _VSPEED_DIV)


def _encode_timestamp(unix_time_sec: int) -> int:
    """UTC 時間内経過秒 × 10 → uint16 (0.1 秒単位、最大 3600 秒)。"""
    ts = (unix_time_sec % 3600) * 10
    return ts & 0xFFFF


def build_basic_id_message(
    uas_id: bytes = b"UAV-ZKP-M1-DEMO00",
    id_type: int  = ODID_IDTYPE_SERIAL_NUMBER,
    ua_type: int  = ODID_UATYPE_HELICOPTER_OR_MULTIROTOR,
) -> bytes:
    """25 バイト BasicID メッセージ (opendroneid-core-c 準拠)。

    Byte 0  : [MessageType(4)][ProtoVersion(4)]
    Byte 1  : [IDType(4)][UAType(4)]  ← LSB=UAType, MSB=IDType
    Bytes 2-21: UAS_ID (20 bytes ASCII, null-padded)
    Bytes 22-24: Reserved
    """
    header   = (ODID_MESSAGETYPE_BASIC_ID << 4) | ODID_PROTOCOL_VERSION
    id_ua    = ((id_type & 0x0F) << 4) | (ua_type & 0x0F)
    uas_id_b = uas_id[:ODID_ID_SIZE].ljust(ODID_ID_SIZE, b"\x00")
    return struct.pack("<BB20s3s", header, id_ua, uas_id_b, b"\x00\x00\x00")


def build_location_message(sample: TelemetrySample) -> bytes:
    """25 バイト Location メッセージ (opendroneid-core-c 準拠)。

    Byte 0  : [MessageType(4)][ProtoVersion(4)]
    Byte 1  : [Status(4)][Reserved(1)][HeightType(1)][EWDir(1)][SpeedMult(1)]
    Byte 2  : Direction (uint8)
    Byte 3  : SpeedHorizontal (uint8)
    Byte 4  : SpeedVertical (int8)
    Bytes 5-8  : Latitude  (int32 LE, 1e-7°)
    Bytes 9-12 : Longitude (int32 LE, 1e-7°)
    Bytes 13-14: AltitudeBaro (uint16 LE, QFE)
    Bytes 15-16: AltitudeGeo  (uint16 LE, WGS84)
    Bytes 17-18: Height (uint16 LE, 0xFFFF=unknown)
    Byte 19 : [VertAccuracy(4)][HorizAccuracy(4)]
    Byte 20 : [BaroAccuracy(4)][SpeedAccuracy(4)]
    Bytes 21-22: TimeStamp (uint16 LE, 0.1秒単位)
    Byte 23 : [Reserved(4)][TSAccuracy(4)]
    Byte 24 : Reserved
    """
    header = (ODID_MESSAGETYPE_LOCATION << 4) | ODID_PROTOCOL_VERSION

    ew_dir, dir_enc = _encode_direction(0.0)   # 方向不明 → 0
    speed_mult, speed_h_enc = _encode_speed_h(0.0)
    speed_v_enc = _encode_speed_v(0.0)

    # Byte 1: Status=AIRBORNE(2) in bits 4-7, flags in bits 0-3
    height_type = ODID_HEIGHT_REF_OVER_TAKEOFF
    byte1 = (
        ((ODID_STATUS_AIRBORNE & 0x0F) << 4) |
        (0 << 3) |                               # Reserved
        ((height_type & 0x01) << 2) |
        ((ew_dir & 0x01) << 1) |
        (speed_mult & 0x01)
    )

    lat_i32  = round(sample.latitude  * _LATLON_MULT)
    lon_i32  = round(sample.longitude * _LATLON_MULT)
    alt_baro = _encode_altitude(sample.altitude_baro_m)
    alt_geo  = _encode_altitude(sample.altitude_geo_m)
    ts       = _encode_timestamp(sample.unix_time_sec)

    # Byte 19: [VertAccuracy(MSB)][HorizAccuracy(LSB)]
    # Byte 20: [BaroAccuracy(MSB)][SpeedAccuracy(LSB)]
    # すべて 0 = UNKNOWN
    acc_byte19 = 0  # (vert_acc << 4) | horiz_acc
    acc_byte20 = 0  # (baro_acc << 4) | speed_acc
    ts_acc     = 0  # [Reserved(4)][TSAccuracy(4)]

    return struct.pack(
        "<BBBBbiiHHHBBHBB",
        header,
        byte1,
        dir_enc,
        speed_h_enc,
        speed_v_enc,
        lat_i32,
        lon_i32,
        alt_baro,
        alt_geo,
        0xFFFF,      # Height above ground: unknown
        acc_byte19,
        acc_byte20,
        ts,
        ts_acc,
        0,           # Reserved
    )


# ── BLE Advertising ペイロード構築 ─────────────────────────────────────────────

def _hex_bytes(data: bytes) -> list[str]:
    return [f"{b:02X}" for b in data]


def build_adv_payload(message: bytes) -> bytes:
    """25 バイト ODID メッセージを BLE Service Data AD 要素でラップ (29 バイト)。"""
    assert len(message) == ODID_MESSAGE_SIZE
    uuid_le    = struct.pack("<H", ODID_SERVICE_UUID)      # FA FF
    ad_content = bytes([0x16]) + uuid_le + message          # type(1)+uuid(2)+msg(25) = 28B
    ad_element = bytes([len(ad_content)]) + ad_content      # len(1)+28 = 29B
    padded     = ad_element + bytes(31 - len(ad_element))   # zero-pad to 31
    return bytes([len(ad_element)]) + padded                 # [29][31B]


# ── HCI コマンド ───────────────────────────────────────────────────────────────

def _run(args: list[str]) -> None:
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def configure_adapter() -> None:
    # hci0 が既に UP の場合も非ゼロを返すため、エラーを無視する
    subprocess.run(
        ["sudo", "hciconfig", HCI_DEV, "up"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    _run([
        "sudo", "hcitool", "-i", HCI_DEV, "cmd",
        "0x08", "0x0006",
        "A0", "00", "A0", "00",
        "03",
        "00", "00", "00", "00", "00", "00", "00",
        "07", "00",
    ])


def enable_advertising(enabled: bool) -> None:
    _run([
        "sudo", "hcitool", "-i", HCI_DEV, "cmd",
        "0x08", "0x000A",
        "01" if enabled else "00",
    ])


def set_advertising_data(payload: bytes) -> None:
    _run([
        "sudo", "hcitool", "-i", HCI_DEV, "cmd",
        "0x08", "0x0008",
        *_hex_bytes(payload),
    ])


# ── CLI ────────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="OpenDroneID (ASTM F3411-22a) BLE broadcaster — opendroneid-core-c 準拠",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--gps", action="store_true", help="GPS+BME280 実機センサーを使用")
    parser.add_argument("--gps-port",    type=str, default=None)
    parser.add_argument("--bme280-addr", type=lambda x: int(x, 0), default=_BME280_ADDR_DEFAULT)
    parser.add_argument("--lat",       type=float, default=35.6891390)
    parser.add_argument("--lon",       type=float, default=139.6917000)
    parser.add_argument("--alt",       type=float, default=12.0)
    parser.add_argument("--json-path", type=str)
    parser.add_argument("--interval",  type=float, default=1.0)
    parser.add_argument("--uas-id",    type=str, default="UAV-ZKP-M1-DEMO00",
                        help="UAS ID (最大20文字 ASCII)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    uas_id_bytes = args.uas_id.encode("ascii")[:ODID_ID_SIZE]

    if args.gps:
        port = args.gps_port or _detect_gps_port()
        provider: TelemetryProvider = GpsBme280TelemetryProvider(
            gps_port=port, bme280_addr=args.bme280_addr,
        )
        print("センサーモード: GPS + BME280 で起動しました。GPS Fix 待機中...")
    elif args.json_path:
        provider = JsonTelemetryProvider(args.json_path)
        print(f"JSON モード: {args.json_path}")
    else:
        provider = StaticTelemetryProvider(args.lat, args.lon, args.alt)
        print(f"固定値モード: lat={args.lat} lon={args.lon} alt={args.alt}m")

    configure_adapter()
    enable_advertising(False)

    print(
        f"\nOpenDroneID BLE broadcasting (opendroneid-core-c 準拠)\n"
        f"  service_uuid  = 0x{ODID_SERVICE_UUID:04X}\n"
        f"  proto_version = {ODID_PROTOCOL_VERSION} (ASTM F3411-22a)\n"
        f"  uas_id        = {args.uas_id}\n"
        f"  interval      = {args.interval}s\n"
        f"  status        = AIRBORNE ({ODID_STATUS_AIRBORNE})\n"
    )

    seq = 0
    try:
        while True:
            sample = provider.read()

            if seq % 2 == 0:
                msg      = build_location_message(sample)
                msg_type = "Location"
            else:
                msg      = build_basic_id_message(uas_id=uas_id_bytes)
                msg_type = "BasicID "

            payload = build_adv_payload(msg)
            set_advertising_data(payload)
            enable_advertising(True)

            no_fix = (sample.latitude == 0.0 and sample.longitude == 0.0)
            print(
                f"[seq={seq:03d} {msg_type}] "
                f"lat={sample.latitude:.7f}  lon={sample.longitude:.7f}  "
                f"alt_geo={sample.altitude_geo_m:.1f}m  "
                f"alt_baro={sample.altitude_baro_m:.1f}m  "
                f"time={sample.unix_time_sec}"
                + (" [NO FIX]" if no_fix else "")
            )
            seq = (seq + 1) % 256
            time.sleep(args.interval)

    except KeyboardInterrupt:
        enable_advertising(False)
        print("\nAdvertising stopped.")


if __name__ == "__main__":
    main()
