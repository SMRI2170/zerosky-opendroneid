# opendroneid-core-c 準拠対応ログ

## 概要

Pi 送信側（`remote_id.py`）と Flutter 受信側（`main.dart`）を  
[opendroneid-core-c](https://github.com/opendroneid/opendroneid-core-c) の仕様に準拠させた。  
合わせて Pi 起動時のエラーを修正し、BLE 受信の動作確認まで完了した。

---

## 1. Flutter 受信側（`main.dart`）の更新

### 問題

`UavTelemetryPacket` のデコード処理がopendroneid-core-cの仕様と**3箇所ずれていた**。

#### 1-1. Location Byte 1 のビットレイアウトが逆だった

```
【修正前コメント】 Byte 1 : Status[3:0] | flags   ← Status が下位ニブル
【正しい仕様】     Byte 1 : Status[7:4] | flags[3:0] ← Status が上位ニブル
```

opendroneid-core-c の `ODID_Location_encoded_t` では Status は **bits 7:4（上位ニブル）** に入る。  
修正後のデコード：

```dart
final byte1     = rawBytes[1] & 0xFF;
final status    = (byte1 >> 4) & 0x0F;   // bits 7:4 ← 修正
final ewDir     = (byte1 >> 1) & 0x01;   // bit 1
final speedMult = byte1 & 0x01;           // bit 0
```

#### 1-2. AIRBORNE の値が違った

```
【修正前】 AIRBORNE = 1（暗黙的）
【修正後】 AIRBORNE = 2  （opendroneid-core-c: GROUND=1, AIRBORNE=2）
```

#### 1-3. BasicID Byte 1 のニブルが逆だった

```
【修正前コメント】 Byte 1 : IDType[3:0] | UAType[7:4]  ← IDType が下位ニブル
【正しい仕様】     Byte 1 : (IDType << 4) | UAType      ← IDType が上位ニブル
```

#### 1-4. 方向・速度のデコードが未実装だった

opendroneid-core-c では方向と速度にそれぞれフラグがある：

| フラグ | ビット | 意味 |
|--------|--------|------|
| EWDirection | bit 1 | 1 のとき direction = raw + 180（西半球） |
| SpeedMult | bit 0 | 0: ×0.25 m/s（低速域）、1: ×0.75 m/s（高速域） |
| SpeedVertical | byte 4 | int8 × 0.5 m/s（正=上昇） |

```dart
static double _decodeDirection(int raw, int ewDir) {
  return ewDir == 1 ? raw + 180.0 : raw.toDouble();
}
static double _decodeSpeedH(int raw, int speedMult) {
  return speedMult == 1 ? raw * 0.75 : raw * 0.25;
}
static double _decodeSpeedV(int raw) {
  final signed = raw >= 128 ? raw - 256 : raw;
  return signed * 0.5;
}
```

### 追加フィールド

| フィールド | 内容 |
|-----------|------|
| `altitudeMeters` | AltitudeBaro（BME280 QFE 基準） |
| `altitudeGeoMeters` | AltitudeGeo（GPS WGS84 高度）← 新規追加 |
| `speedH` | 水平速度 m/s ← 新規追加 |
| `speedV` | 垂直速度 m/s ← 新規追加 |
| `direction` | 進行方向 degrees ← 新規追加 |
| `statusIsAirborne` | 飛行中フラグ ← 新規追加 |

---

## 2. Pi 送信側（`remote_id.py`）の転送

前セッションで完成した opendroneid-core-c 準拠版を Pi に転送。

```bash
scp uav/remote_id.py pi@192.168.11.54:/home/pi/remote_id.py
```

---

## 3. Pi 起動時エラーと修正

### エラー内容

```
Traceback (most recent call last):
  File "/home/pi/remote_id.py", line 525, in <module>
    main()
  File "/home/pi/remote_id.py", line 479, in main
    configure_adapter()
  File "/home/pi/remote_id.py", line 415, in configure_adapter
    _run(["sudo", "hciconfig", HCI_DEV, "up"])
  File "/home/pi/remote_id.py", line 411, in _run
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.CalledProcessError: Command '['sudo', 'hciconfig', 'hci0', 'up']`
    returned non-zero exit status 1.
```

### 原因

`hci0` が既に `UP RUNNING` 状態のとき、`hciconfig hci0 up` はエラーコード 1 を返す。  
`subprocess.run(..., check=True)` がそれを例外として扱っていた。

確認結果：

```
hci0:  Type: Primary  Bus: UART
       BD Address: D8:3A:DD:E2:55:36  ACL MTU: 1021:8  SCO MTU: 64:1
       UP RUNNING        ← 既に起動済みだった
       RX bytes:5430  TX bytes:73114
```

### 修正

```python
# 修正前
def configure_adapter() -> None:
    _run(["sudo", "hciconfig", HCI_DEV, "up"])  # check=True で失敗する

# 修正後
def configure_adapter() -> None:
    # hci0 が既に UP の場合も非ゼロを返すため、エラーを無視する
    subprocess.run(
        ["sudo", "hciconfig", HCI_DEV, "up"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
```

`check=True` を外すことで、既に UP の場合も正常続行するようにした。

---

## 4. 動作確認結果

### Pi 側（送信）

```
GPS: /dev/ttyACM0 を開きました
BME280: I2C 0x76 地上気圧=1003.5hPa
センサーモード: GPS + BME280 で起動しました。GPS Fix 待機中...

OpenDroneID BLE broadcasting (opendroneid-core-c 準拠)
  service_uuid  = 0xFFFA
  proto_version = 2 (ASTM F3411-22a)
  uas_id        = UAV-ZKP-M1-DEMO00
  interval      = 1.0s
  status        = AIRBORNE (2)

[seq=001 BasicID ] lat=34.9685812  lon=135.8992150  alt_geo=124.2m  alt_baro=-0.3m
[seq=002 Location] lat=34.9685810  lon=135.8992148  alt_geo=124.2m  alt_baro=0.8m
[seq=003 BasicID ] lat=34.9685810  lon=135.8992147  alt_geo=124.2m  alt_baro=0.2m
...（以降 1秒ごとに継続）
```

| 確認項目 | 結果 |
|---------|------|
| GPS Fix | 起動後すぐに取得 |
| BME280 | I2C 0x76 正常、QFE 高度 ≈ 0m |
| BLE 送信 | 1秒ごとに Location / BasicID 交互送信 |
| opendroneid-core-c 準拠 | AIRBORNE=2、Status 上位ニブル |

### Flutter 側（受信）

Android アプリでドローン ID の受信を確認。

---

## 5. 最終構成

```
Pi (remote_id.py)               Flutter (main.dart)
────────────────────            ───────────────────
opendroneid-core-c 準拠         opendroneid-core-c 準拠
Status 上位ニブル (bits 7:4)    Status 上位ニブル (bits 7:4)
AIRBORNE = 2                    AIRBORNE = 2
IDType 上位ニブル               IDType 上位ニブル
EWDirection / SpeedMult 実装    EWDirection / SpeedMult デコード実装
        │  BLE (Service UUID 0xFFFA)  │
        └─────────────────────────────┘
              双方のビットレイアウト一致 ✓
```
