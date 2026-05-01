# センサー統合・実装ログ

## 概要

Raspberry Pi に接続した GPS モジュール（USB CDC）と BME280（I2C 気圧センサー）を  
`remote_id.py` に組み込み、実機からリアルタイムでドローンの位置・高度を取得する。  
スマホ側（Flutter）も同じ高度基準（QFE）に揃え、ZK 証明の入力値の整合性を確保する。

---

## 1. ハードウェア構成

| デバイス | 接続 | アドレス／ポート |
|---------|------|----------------|
| GPS モジュール（u-blox 等） | USB CDC | `/dev/ttyACM0` |
| BME280 温湿度気圧センサー | I²C | `0x76`（SDO=GND） |
| Raspberry Pi | — | IP: 192.168.11.54 |

---

## 2. remote_id.py の変更内容

### 2-1. 変更前（静的値）

```python
class StaticTelemetryProvider:
    def read(self):
        return TelemetrySample(
            latitude=self.latitude,   # ← CLI 引数の固定値
            longitude=self.longitude, # ← CLI 引数の固定値
            altitude_m=self.altitude_m,
            unix_time_sec=int(time.time()),  # タイムスタンプのみ実時刻
        )
```

- 緯度・経度は起動時の CLI 引数または JSON ファイルの固定値
- GPS モジュールと接続していない
- 高度は `1013.25 hPa`（標準大気）基準の絶対高度

### 2-2. 変更後（実機センサー）

```bash
# 起動コマンド
python3 remote_id.py --gps
python3 remote_id.py --gps --gps-port /dev/ttyUSB0
python3 remote_id.py --gps --bme280-addr 0x77
```

#### 追加クラス: `GpsBme280TelemetryProvider`

| 機能 | 実装 |
|------|------|
| GPS 受信 | `pyserial` でシリアル開放、`pynmea2` で NMEA 解析 |
| GPS 処理スレッド | `daemon=True` の別スレッドで常時受信・ロック共有 |
| BME280 読み取り | 毎回 `bme280.sample()` を呼び出し（`smbus2`） |
| 高度基準（QFE） | 起動時の気圧を `_ground_pressure_hpa` に記録 |
| GPS ポート自動検出 | `/dev/ttyACM0` → `ttyUSB0` → `ttyAMA0` の順に試す |
| No Fix 表示 | 座標 `(0,0)` の間は `[NO FIX]` をログに表示 |

#### GPS 受信スレッドの動作

```
NMEA 文をシリアルから読む
   ├── $GNGGA → lat / lon / alt_geo 取得（Fix 確認）
   ├── $GNRMC → lat / lon のみ（alt は直前の GGA 値を維持）
   └── その他 → スキップ
BME280 から気圧取得 → QFE 高度計算
TelemetrySample を更新（排他ロック）
```

### 2-3. `TelemetrySample` の変更

```python
# 変更前
@dataclass
class TelemetrySample:
    altitude_m: float          # 気圧・GPS を混在

# 変更後
@dataclass
class TelemetrySample:
    altitude_geo_m:  float     # GPS 高度 (WGS84 楕円体高)
    altitude_baro_m: float     # 気圧高度 (BME280, QFE 基準)
```

OpenDroneID の Location メッセージに対応:
- `AltitudeBaro` ← BME280 の QFE 高度
- `AltitudeGeo`  ← GPS の WGS84 高度

---

## 3. QFE 高度方式（最重要変更）

### 問題

| 方式 | 問題点 |
|------|--------|
| 標準大気 (1013.25 hPa) 基準 | 実際の海面気圧は天気で変化（±10 hPa 以上）→ 絶対高度がずれる |
| GPS 高度 | WGS84 楕円体高で精度が低い（誤差 ±10〜30m 以上） |
| 両センサーの基準が違う | Pi の BME280 とスマホの気圧計の出す値が異なる基準になる |

### 解決策: QFE（Height Above Takeoff）

```
起動時の気圧 P₀ を記録し、以後は P₀ からの相対高度を使う
alt = 44330 × (1 - (P_現在 / P₀)^(1/5.255))
```

| タイミング | 値 |
|-----------|-----|
| 地上（起動直後） | `alt ≈ 0 m` |
| 10m 上昇 | `alt ≈ 10 m` |
| 天気が変わっても | 相対差は正確（P₀ も P_現在 も同様に変化するため） |

### Pi 側の実装

```python
# 起動時に地上気圧を記録
first = bme280_lib.sample(bus, bme280_addr, params)
self._ground_pressure_hpa = first.pressure   # 例: 1005.6 hPa

# 毎回の高度計算
alt = 44330.0 * (1.0 - (P_now / self._ground_pressure_hpa) ** (1.0 / 5.255))
```

### Flutter 側の実装

```dart
// アプリ起動時の最初の気圧値を地上基準として記録
_groundPressureHpa ??= event.pressure;

// QFE 高度計算ヘルパー
double _baroToRelativeAlt(double pressureHpa) {
  final p0 = _groundPressureHpa;
  if (p0 == null || p0 <= 0) return 0.0;
  return 44330.0 * (1.0 - math.pow(pressureHpa / p0, 1.0 / 5.255));
}
```

### なぜこれで両者が整合するか

```
Pi   起動時 P₀ = 1005.6 hPa  →  地上 = 0m、飛行10m → 10m
スマホ 起動時 P₀ = 1005.5 hPa  →  地上 = 0m

ドローンとユーザーが同じ場所で起動 → P₀ がほぼ同値
→ 高度差 = 実際の物理的な高さの差
```

---

## 4. Flutter アプリの変更

### 4-1. 録画修正

| 変更 | 理由 |
|------|------|
| `imageFormatGroup: ImageFormatGroup.jpeg` を削除 | 一部 Android 端末で動画録画と競合する |
| `catch (_) {}` → `catch (e) { setState(() => _status = ...) }` | エラーを画面に表示して原因を特定できるようにする |

### 4-2. GPS 1 秒更新

```dart
// 変更前: 移動がないと更新されない可能性
LocationSettings(distanceFilter: 0)

// 変更後: Android で毎秒強制更新
Platform.isAndroid
  ? AndroidSettings(intervalDuration: Duration(seconds: 1))
  : LocationSettings(distanceFilter: 0)
```

---

## 5. 動作確認結果（Raspberry Pi 実機）

```
GPS: /dev/ttyACM0 を開きました
BME280: I2C addr=0x76 地上気圧=1005.6hPa

[seq=001 Location] lat=34.9686023  lon=135.8991972  alt_geo=122.1m  alt_baro=0.0m  time=1777524442
[seq=002 Location] lat=34.9686023  lon=135.8991973  alt_geo=122.1m  alt_baro=0.1m  time=1777524443
...
```

| 項目 | 確認結果 |
|------|---------|
| GPS Fix | 起動後 1〜2秒で取得 |
| GPS ポート | `/dev/ttyACM0`（自動検出） |
| BME280 | I2C `0x76` で正常読み取り |
| BLE ブロードキャスト | 1秒ごとに Location / BasicID 交互送信 |
| QFE 高度 | 地上 ≈ 0m から計測開始 |

---

## 6. 依存ライブラリ（Raspberry Pi）

```bash
pip install pyserial pynmea2 smbus2 RPi.bme280 --break-system-packages
```

| ライブラリ | 用途 |
|-----------|------|
| `pyserial` | GPS シリアル通信 |
| `pynmea2` | NMEA 文解析 |
| `smbus2` | I²C 通信 |
| `RPi.bme280` | BME280 センサードライバ |

---

## 7. 起動手順

```bash
# Raspberry Pi で実行
python3 remote_id.py --gps

# GPS ポートを明示する場合
python3 remote_id.py --gps --gps-port /dev/ttyUSB0

# BME280 アドレスが 0x77 の場合（SDO ピンが VCC 接続）
python3 remote_id.py --gps --bme280-addr 0x77
```
