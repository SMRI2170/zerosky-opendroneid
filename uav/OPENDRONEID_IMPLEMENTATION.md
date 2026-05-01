# OpenDroneID (ASTM F3411-22a) 実装解説

このドキュメントでは、本プロジェクトにおける OpenDroneID 規格の配信・受信の実装を詳細に説明します。

---

## 1. OpenDroneID とは

**ASTM F3411** として標準化された、ドローンが自身の識別情報と位置情報を周囲に BLE または Wi-Fi でブロードキャストするための国際規格です。

| 規格名 | 内容 |
|---|---|
| ASTM F3411-22a | 米国 ASTM International 制定（2022年版） |
| ASD-STAN prEN 4709-002 | 欧州版（ASTM と相互運用性あり） |
| 日本航空法 改正（2022年6月） | 100g 以上の機体にリモートID搭載義務 |

---

## 2. プロジェクト変更の概要

### 変更前（独自フォーマット）

```
BLE Manufacturer Specific Data (AD type 0xFF)
  Company ID: 0x02E5
  Payload: [MAGIC=0x5A][VERSION=0x01][lat_e7 4B][lon_e7 4B][alt_dm 2B][unix_time 4B][seq 1B]
  = 合計 17 バイト（独自仕様）
```

### 変更後（OpenDroneID 準拠）

```
BLE Service Data (AD type 0x16)
  Service UUID: 0xFFFA
  Payload: [25 バイトの ASTM F3411 メッセージ]
  = 合計 29 バイト（規格準拠）
```

---

## 3. BLE ペイロード構造の詳細

### 3.1 AD 要素の構造

```
オクテット:  [0]      [1]   [2]  [3]   [4..28]
内容:       length   0x16  0xFA 0xFF  25バイトメッセージ
            (=28)    AD    UUID (LE)
                     type
```

- **length = 28 (0x1C)**: type(1) + UUID(2) + message(25) の合計バイト数
- **AD type 0x16**: Service Data - 16-bit UUID
- **UUID 0xFFFA** (little-endian: `FA FF`): OpenDroneID 専用 Service UUID
- **25バイトメッセージ**: ASTM F3411 が定める固定長メッセージ

合計 29 バイト → BLE 31 バイト制限内に収まる。

### 3.2 BasicID メッセージ（25バイト）

機体の識別子と種別を送信する。

```
Byte 0:    Header = (MessageType=0 << 4) | ProtoVersion
              例: 0x02 = (0<<4)|2  ← ASTM F3411-22a は version 2
Byte 1:    IDType[3:0] | UAType[7:4]
              例: 0x21 = IDType=1(Serial) | UAType=2(Multirotor)<<4
Bytes 2-21: UAS_ID (20バイト ASCII、null パディング)
              例: "UAV-ZKP-M1-DEMO00\x00\x00"
Bytes 22-24: Reserved (0x00 0x00 0x00)
```

**実際の送信例（hex）:**
```
02 21 55 41 56 2D 5A 4B 50 2D 4D 31 2D 44 45 4D 4F 30 30 00 00 00 00 00 00
↑   ↑  ↑───── "UAV-ZKP-M1-DEMO00" ──────────────────────────────↑  ↑── reserved
型  ID UAV種別
```

### 3.3 Location メッセージ（25バイト）

現在位置・高度・速度・タイムスタンプを送信する。**1秒に1回以上**の送信が義務。

```
Byte 0:    Header = (MessageType=1 << 4) | ProtoVersion
              例: 0x12 = (1<<4)|2
Byte 1:    Status[3:0] | HeightType[4] | EWDirection[5] | SpeedMult[6] | Reserved[7]
              例: 0x01 = Status=1(Airborne), 他は 0
Byte 2:    Direction (uint8, 2度単位 0-179, or +180 if EWDirection=1)
              0 = 不明
Byte 3:    SpeedHorizontal (uint8, SpeedMult=0 時: 0.25m/s 単位)
              0 = 静止
Byte 4:    SpeedVertical (int8, 0.5m/s 単位, 範囲 -62〜+62)
              0 = 静止
Bytes 5-8:   Latitude  (int32 LE, 1e-7 度)
              例: 35.6891390° → 356,891,390 → 0xFE BA 45 15 15 (LE)
Bytes 9-12:  Longitude (int32 LE, 1e-7 度)
              例: 139.6917000° → 1,396,917,000 → 0x08 43 43 53 (LE)
Bytes 13-14: AltitudeBaro (uint16 LE, (alt_m + 1000) * 2)
              例: 12.0m → (12+1000)*2 = 2024 → 0xE8 0x07
Bytes 15-16: AltitudeGeo  (uint16 LE, 同上エンコード)
Bytes 17-18: Height above ground (uint16 LE, 0xFFFF = 不明)
Byte 19:     HorizAccuracy[3:0] | VertAccuracy[7:4]  (0 = 不明)
Byte 20:     BaroAccuracy[3:0]  | SpeedAccuracy[7:4] (0 = 不明)
Bytes 21-22: Timestamp (uint16 LE, UTC の時間内経過秒 × 10)
              例: 1711447200 sec → (1711447200 % 3600) * 10 = 19310 → 0x4B 0x6E
Byte 23:     TSAccuracy[3:0] | Reserved[7:4]
Byte 24:     Reserved
```

**実際の送信例（hex）:**
```
12 01 00 00 00 FE BA 45 15 08 43 43 53 E8 07 E8 07 FF FF 00 00 6E 4B 00 00
↑  ↑           ↑──────────↑ ↑──────────↑ ↑───↑ ↑───↑ ↑───↑     ↑───↑
│  │           lat=35.689  lon=139.691  baro geo  H    acc   timestamp
type status
```

---

## 4. 送信側実装（Raspberry Pi）

### ファイル: `uav/remote_id.py`

#### 送信サイクル

BasicID と Location を **1秒ごとに交互**に送信する。

```
tick 0: Location  → 現在位置・高度・時刻
tick 1: BasicID   → 機体識別子・種別
tick 2: Location
tick 3: BasicID
...
```

これにより 8 秒間スキャンすれば Location を最低 4 回受信できる。

#### 高度エンコード

```python
def _encode_altitude(alt_m: float) -> int:
    # raw = (alt_m + 1000) * 2
    # -1000m (海底) 〜 +31767m (成層圏) に対応
    raw = round((alt_m + 1000) * 2)
    return max(0, min(0xFFFE, raw))  # 0xFFFF は「不明」予約済み
```

#### タイムスタンプ

OpenDroneID は Unix 絶対時刻ではなく「UTC 時間内の経過秒 × 10」を送信する。

```python
ts = (sample.unix_time_sec % 3600) * 10
# 例: 1711447200 sec → 1711447200 % 3600 = 1920 sec → ts = 19200
```

受信側はこれと現在時刻から絶対 Unix 秒を再構築する。

#### HCI コマンドで BLE 送信

`hcitool` を使って Raw HCI コマンドを直接発行する。

```python
# 広告パラメータ設定（0x0006）
# ADV_NONCONN_IND（接続不要）、160ms インターバル
sudo hcitool -i hci0 cmd 0x08 0x0006 A0 00 A0 00 03 ...

# 広告データ設定（0x0008）
# [29][AD要素 29バイト][ゼロパディング 2バイト]
sudo hcitool -i hci0 cmd 0x08 0x0008 1D 1C 16 FA FF [25バイトメッセージ] 00 00

# 広告有効化（0x000A）
sudo hcitool -i hci0 cmd 0x08 0x000A 01
```

#### 使い方

```bash
# 固定座標を 1 秒ごとに送信
python3 uav/remote_id.py --lat 35.6891390 --lon 139.6917000 --alt 12.0

# JSON ファイルから動的に読み込む（飛行中に更新可能）
python3 uav/remote_id.py --json-path uav_sample.json --interval 0.5

# バックグラウンドで継続実行
nohup sudo python3 uav/remote_id.py --lat 35.689 --lon 139.691 --alt 12.0 \
  > /tmp/remote_id.log 2>&1 &
```

---

## 5. 受信側実装（Flutter アプリ）

### ファイル: `rapidsnark_app/lib/main.dart`

#### UavTelemetryPacket クラス

OpenDroneID パーサーとして全面再設計。

```dart
class UavTelemetryPacket {
  // OpenDroneID BLE Service UUID (16-bit 0xFFFA の 128-bit 展開)
  static const serviceUuid = '0000fffa-0000-1000-8000-00805f9b34fb';

  static const _msgTypeBasicId  = 0;  // Header byte の上位 4 bit = 0
  static const _msgTypeLocation = 1;  // Header byte の上位 4 bit = 1
```

**Location メッセージのパース:**

```dart
static UavTelemetryPacket? tryParseLocation(List<int>? rawBytes, int seq) {
  if (rawBytes == null || rawBytes.length < 25) return null;
  final msgType = (rawBytes[0] >> 4) & 0x0F;   // 上位 4 bit がメッセージタイプ
  if (msgType != _msgTypeLocation) return null;

  final data = ByteData.sublistView(Uint8List.fromList(rawBytes));
  final latI32  = data.getInt32(5,  Endian.little);  // Bytes 5-8
  final lonI32  = data.getInt32(9,  Endian.little);  // Bytes 9-12
  final altGeo  = data.getUint16(15, Endian.little); // Bytes 15-16
  final tsRaw   = data.getUint16(21, Endian.little); // Bytes 21-22

  return UavTelemetryPacket(
    latitude:       latI32 / 1e7,
    longitude:      lonI32 / 1e7,
    altitudeMeters: altGeo / 2.0 - 1000.0,         // 逆エンコード
    unixTimeSec:    _reconstructUnixTime(tsRaw),    // 時間内秒 → Unix 秒
    sequence:       seq,
  );
}
```

**タイムスタンプ再構築:**

```dart
static int _reconstructUnixTime(int tsRaw) {
  if (tsRaw == 0xFFFF) return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final secondsWithinHour = tsRaw ~/ 10;         // 1/10 秒 → 秒
  final nowSec    = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final hourStart = nowSec - (nowSec % 3600);    // 現在時刻の時間境界
  return hourStart + secondsWithinHour;
}
```

**BasicID メッセージから UAS_ID 取得:**

```dart
static String? tryParseUasId(List<int>? rawBytes) {
  if (rawBytes == null || rawBytes.length < 25) return null;
  final msgType = (rawBytes[0] >> 4) & 0x0F;
  if (msgType != _msgTypeBasicId) return null;

  final idBytes = rawBytes.sublist(2, 22);  // Bytes 2-21
  final nullIdx = idBytes.indexOf(0);
  return String.fromCharCodes(
    nullIdx >= 0 ? idBytes.sublist(0, nullIdx) : idBytes
  ).trim();
}
```

**Service Data の UUID 検索:**

flutter_blue_plus は serviceData を `Map<Guid, List<int>>` で返すが、
Guid の文字列表現がプラットフォームによって異なる場合があるため、
`0xFFFA` を含む文字列を大小文字問わず検索する。

```dart
static List<int>? extractFromServiceData(Map<dynamic, List<int>> serviceData) {
  for (final entry in serviceData.entries) {
    if (entry.key.toString().toLowerCase().contains('fffa')) {
      return entry.value;
    }
  }
  return null;
}
```

#### BLE スキャンフロー（`_fillDroneFromBle`）

```
1. FlutterBluePlus.adapterState で Bluetooth オン確認
2. FlutterBluePlus.startScan(timeout: 10秒)
3. scanResults.listen でパケットを受信
4. serviceData から UUID 0xFFFA を探す
5. BasicID → UAS_ID を保存（受信継続）
6. Location → UavTelemetryPacket に変換して完了
7. フォームに lat / lon / alt / unixTime を自動入力
```

---

## 6. 独自フォーマットとの対応表

| フィールド | 独自フォーマット | OpenDroneID |
|---|---|---|
| 識別子 | Manufacturer Data, Company ID 0x02E5 | Service Data, UUID 0xFFFA |
| 緯度・経度 | int32 LE, 1e-7 度 | **同じ** |
| 高度 | int16 LE, デシメートル（0.1m単位）| uint16 LE, (alt+1000)*2（0.5m単位）|
| タイムスタンプ | uint32 LE, Unix 秒（絶対値）| uint16 LE, 時間内秒×10（相対値）|
| 機体識別子 | なし | BasicID の UAS_ID（20バイト ASCII）|
| 速度・方向 | なし | Direction / SpeedH / SpeedV |
| 精度情報 | なし | HorizAccuracy / VertAccuracy など |
| シーケンス | uint8 (0-255) | 回路内でカウント（アプリ側管理）|

---

## 7. 既存市販機器との互換性

OpenDroneID 準拠に変更したことで、以下と互換性が生まれます。

- **市販の Remote ID 送信モジュール**（DJI, Autel, SkySafe 等）
- **OpenDroneID 受信アプリ**（DroneScanner, OpenDroneID Receiver 等）
- **規制当局の検査機器**（FAAや国交省が使用する地上受信機）

---

## 8. ZK 証明フローへの接続

受信した OpenDroneID Location メッセージのフィールドは、以下のように ZK 回路の入力に変換される。

```
Location.latitude     → drone_lat_e7_norm = round((lat + 90) * 1e7)
Location.longitude    → drone_lon_e7_norm = round((lon + 180) * 1e7)
Location.altitudeGeo  → drone_alt_cm      = round(alt_m * 100)
Location.timestamp    → drone_time_sec    = _reconstructUnixTime(tsRaw)
```

回路内では Poseidon ハッシュが計算され、実際の座標値は外部に公開されない。

---

## 9. 今後の拡張方針

| 項目 | 内容 |
|---|---|
| BT5 Long Range | Extended Advertising を使い MessagePack で複数メッセージを1パケットで送信 |
| Wi-Fi NaN | より広範囲への送信（Pixel 8 は Wi-Fi NaN 受信対応）|
| Authentication | OpenDroneID Auth メッセージで機体の署名検証を追加 |
| IPFS 連携 | BasicID の UAS_ID をキーに IPFS から Merkle Tree を取得 |
| Merkle 証明 | 取得した飛行ログの Merkle Proof を ZK 回路に組み込む |
