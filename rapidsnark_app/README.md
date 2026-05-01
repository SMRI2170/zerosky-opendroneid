# rapidsnark_app

Flutter で動く UAV Safety Proof デモアプリです。  
ドローン側ログと利用者側ログを集めて、動画検知のあとにゼロ知識証明を生成・検証します。

## 機能

- ドローン側ログを `手入力` または `Raspberry Pi BLE 受信` で取得
- 利用者側ログをスマホの `GPS + 気圧センサー` で取得
- カメラで動画を撮影
- 動画から UAV 候補を検知
- 端末内で witness 計算、Groth16 証明生成、検証

## 必要 asset

アプリは次のファイルを `assets/` に必要とします。

- `distance30.wcd`
- `distance30_groth16.zkey`
- `distance30_verification_key.json`

これらはルートで次を実行すると更新できます。

```bash
./scripts/build_distance_assets.sh
```

## 実行方法

```bash
flutter pub get
flutter run
```

## 必要権限

### Android

- `BLUETOOTH_SCAN`
- `BLUETOOTH_CONNECT`
- `ACCESS_FINE_LOCATION`
- `CAMERA`

### iOS

- `NSBluetoothAlwaysUsageDescription`
- `NSLocationWhenInUseUsageDescription`
- `NSCameraUsageDescription`

## 使い方

### 収集タブ

ドローン側ログは 2 モードあります。

- `手入力`
  - 緯度、経度、高度、時刻を直接入れる
- `Raspberry Pi`
  - `Raspberry Pi から受信` を押して BLE manufacturer data を受信する

利用者側ログは `この端末の値を使う` で取得します。

### 検知タブ

- 動画撮影後、自動で複数フレームを解析
- UAV 候補が見つかれば証明へ進める

### 証明タブ

- `Generate And Verify Proof` で証明生成と検証を実行
- `Witness Inputs`, `Public Signals`, `Proof JSON` を確認可能

## Raspberry Pi 連携

Pi 側の送信スクリプトは [remote_id.py](/Users/smri/Downloads/cursor/m1/uav/remote_id.py) です。

例:

```bash
python3 ../uav/remote_id.py --lat 35.6891390 --lon 139.6917000 --alt 12.0
```

アプリは `company_id = 0x02E5` の manufacturer data を探して、緯度・経度・高度・時刻を復元します。

## 補足

- BLE モードでは、`BLE受信から撮影まで進む` を押すと未受信ならそのまま受信を試してから撮影へ進みます
- YOLO モデルが未配置または無効な場合は ML Kit フォールバックで動作します
