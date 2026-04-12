import argparse
import json
import struct
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


HCI_DEV = "hci0"
COMPANY_ID = 0x02E5
MAGIC = 0x5A
VERSION = 0x01


@dataclass
class TelemetrySample:
    latitude: float
    longitude: float
    altitude_m: float
    unix_time_sec: int


class TelemetryProvider:
    def read(self) -> TelemetrySample:
        raise NotImplementedError


class StaticTelemetryProvider(TelemetryProvider):
    def __init__(self, latitude: float, longitude: float, altitude_m: float):
        self.latitude = latitude
        self.longitude = longitude
        self.altitude_m = altitude_m

    def read(self) -> TelemetrySample:
        return TelemetrySample(
            latitude=self.latitude,
            longitude=self.longitude,
            altitude_m=self.altitude_m,
            unix_time_sec=int(time.time()),
        )


class JsonTelemetryProvider(TelemetryProvider):
    def __init__(self, path: str):
        self.path = Path(path)

    def read(self) -> TelemetrySample:
        payload = json.loads(self.path.read_text())
        return TelemetrySample(
            latitude=float(payload["latitude"]),
            longitude=float(payload["longitude"]),
            altitude_m=float(payload["altitude_m"]),
            unix_time_sec=int(payload.get("unix_time_sec", time.time())),
        )


def run_command(args):
    subprocess.run(args, check=True)


def hex_bytes(data: bytes) -> list[str]:
    return [f"{byte:02X}" for byte in data]


def build_adv_data(sample: TelemetrySample, sequence: int) -> bytes:
    lat_e7 = round(sample.latitude * 10_000_000)
    lon_e7 = round(sample.longitude * 10_000_000)
    altitude_dm = round(sample.altitude_m * 10)

    manufacturer_payload = struct.pack(
        "<BBiihIB",
        MAGIC,
        VERSION,
        lat_e7,
        lon_e7,
        altitude_dm,
        sample.unix_time_sec,
        sequence & 0xFF,
    )

    adv_fields = bytearray()
    adv_fields.extend(b"\x02\x01\x06")
    adv_fields.append(len(manufacturer_payload) + 3)
    adv_fields.append(0xFF)
    adv_fields.extend(struct.pack("<H", COMPANY_ID))
    adv_fields.extend(manufacturer_payload)

    if len(adv_fields) > 31:
        raise ValueError(f"Advertising payload too large: {len(adv_fields)} bytes")

    padded = adv_fields + bytes(31 - len(adv_fields))
    return bytes([len(adv_fields)]) + padded


def configure_adapter():
    run_command(["sudo", "hciconfig", HCI_DEV, "up"])
    run_command(
        [
            "sudo",
            "hcitool",
            "-i",
            HCI_DEV,
            "cmd",
            "0x08",
            "0x0006",
            "A0",
            "00",
            "A0",
            "00",
            "03",
            "00",
            "00",
            "00",
            "00",
            "00",
            "00",
            "00",
            "07",
            "00",
        ]
    )


def enable_advertising(enabled: bool):
    run_command(
        [
            "sudo",
            "hcitool",
            "-i",
            HCI_DEV,
            "cmd",
            "0x08",
            "0x000A",
            "01" if enabled else "00",
        ]
    )


def update_advertising_data(sample: TelemetrySample, sequence: int):
    adv_data = build_adv_data(sample, sequence)
    run_command(
        ["sudo", "hcitool", "-i", HCI_DEV, "cmd", "0x08", "0x0008", *hex_bytes(adv_data)]
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Broadcast UAV latitude/longitude/altitude/time over BLE advertising."
    )
    parser.add_argument("--lat", type=float, default=35.6891390)
    parser.add_argument("--lon", type=float, default=139.6917000)
    parser.add_argument("--alt", type=float, default=12.0, help="Altitude in meters.")
    parser.add_argument(
        "--json-path",
        type=str,
        help="Optional JSON file with latitude, longitude, altitude_m, unix_time_sec.",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        help="Advertising refresh interval in seconds.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    provider: TelemetryProvider
    if args.json_path:
        provider = JsonTelemetryProvider(args.json_path)
    else:
        provider = StaticTelemetryProvider(args.lat, args.lon, args.alt)

    configure_adapter()
    enable_advertising(False)

    print(
        "UAV BLE telemetry advertising started. "
        f"company_id=0x{COMPANY_ID:04X}, magic=0x{MAGIC:02X}, version={VERSION}"
    )

    sequence = 0
    try:
        while True:
            sample = provider.read()
            update_advertising_data(sample, sequence)
            enable_advertising(True)
            print(
                "broadcast "
                f"lat={sample.latitude:.7f}, lon={sample.longitude:.7f}, "
                f"alt={sample.altitude_m:.1f}m, time={sample.unix_time_sec}, seq={sequence}"
            )
            sequence = (sequence + 1) % 256
            time.sleep(args.interval)
    except KeyboardInterrupt:
        enable_advertising(False)
        print("Advertising stopped.")


if __name__ == "__main__":
    main()
