# ZK Distance 30m Demo

このディレクトリは、緯度・経度・高度・時刻から「対象とドローンが 30m 以内に近づいたか」をゼロ知識証明するための回路と手順をまとめたものです。

## 判定仕様

- 入力: ドローン側と対象側の `lat/lon/alt/time`
- 緯度経度: `E7` 整数に正規化して回路へ投入
  - `lat_e7_norm = round((latitude + 90) * 1e7)`
  - `lon_e7_norm = round((longitude + 180) * 1e7)`
- 高度: `cm`
- 時刻: `Unix time sec`
- 判定:
  - 3次元距離が `30m` 以下
  - 時刻差が `5秒` 以下

## 追加した回路バリエーション

`circuits/` には、距離・時刻の基本回路に加えて、UAV 検知の扱いを比較するための派生回路を追加している。

- `distance_30m_time.circom`
  - 距離と時刻だけを見る最小構成
- `distance_30m_time_detection_flag.circom`
  - `uav_detected`, `detection_score_bps`, `detection_class_id` を追加
  - 検知フラグだけを回路へ載せる軽量案
- `distance_30m_time_detection_commitment.circom`
  - 検知フラグに加えて `frame_time_sec` とフレーム commitment の存在を追加
  - 検知結果と証拠フレームの結びつきを少し強める案
- `distance_30m_time_feature_classifier.circom`
  - 画像そのものではなく、外部で抽出した 4 次元特徴量を小さな線形分類器で判定
  - フル YOLO を回路化する前の中間案

サンプル入力は `zk-distance/samples/` に置いている。

### バリエーション用スクリプト

- `scripts/build_distance_detection_flag_assets.sh`
- `scripts/build_distance_detection_commitment_assets.sh`
- `scripts/build_distance_feature_classifier_assets.sh`
- `scripts/compare_distance_variant_constraints.sh`

最後のスクリプトを実行すると、`zk-distance/constraint-compare/summary.csv` に回路ごとの制約数比較を出力できる。

## 近似モデル

回路では球面距離ではなく、都市部の近距離判定向けに固定係数の平面近似を使います。

- 緯度スケール: `11132000 cm / 1 degree`
- 経度スケール: `9128800 cm / 1 degree`
  - おおむね北緯35度近辺を想定

## 必要環境

- `circom 2.2.2`
- `snarkjs 0.7.5`
- `node v24.14.0`
- `npm 11.9.0`
- `cargo 1.90.0`
- `rustc 1.90.0`
- `protoc 34.1`
- `Flutter 3.32.5`
- `Dart 3.8.1`

## セットアップ

```bash
./scripts/build_distance_assets.sh
```

このスクリプトは以下を行います。

- `circom` で `r1cs/wasm/sym` を生成
- `snarkjs` で Powers of Tau と Groth16 セットアップを実施
- サンプル witness / proof / public signals を生成
- `rapidsnark_app/assets` に `.zkey` と `verification_key.json` を配置
- `build-circuit` があれば `.wcd` も配置

## rapidsnark_app で必要な追加ツール

`circom_witnesscalc` が使う `.wcd` は `iden3/circom-witnesscalc` の `build-circuit` で生成します。

例:

```bash
git clone https://github.com/iden3/circom-witnesscalc.git /tmp/circom-witnesscalc
cd /tmp/circom-witnesscalc
cargo build --release -p build-circuit
BUILD_CIRCUIT_BIN=/tmp/circom-witnesscalc/target/release/build-circuit ./scripts/build_distance_assets.sh
```

## アプリ側の流れ

1. 座標と時刻を入力
2. Flutter で E7 / cm / sec に正規化
3. `distance30.wcd` で witness を計算
4. `distance30_groth16.zkey` で Groth16 証明を生成
5. `distance30_verification_key.json` で検証

## 出力される公開信号

- `within30`
- `distance_ok`
- `time_ok`

## UAV からスマホへの BLE 配信

`uav/remote_id.py` は、ラズパイ上で UAV の `latitude / longitude / altitude / unix_time_sec` を BLE 広告として配信します。スマホ側は `rapidsnark_app` で広告を受信し、ドローン側ログへ自動入力できます。

### UAV 側

固定値を配信する例:

```bash
python3 uav/remote_id.py --lat 35.6891390 --lon 139.6917000 --alt 12.0
```

JSON ファイルを配信する例:

```bash
python3 uav/remote_id.py --json-path uav_sample.json
```

JSON 形式:

```json
{
  "latitude": 35.6891390,
  "longitude": 139.6917000,
  "altitude_m": 12.0,
  "unix_time_sec": 1711447200
}
```

BLE 広告の manufacturer data には次の内容を入れています。

- `company_id = 0x02E5`
- `magic = 0x5A`
- `version = 0x01`
- `lat_e7` signed int32 little-endian
- `lon_e7` signed int32 little-endian
- `altitude_dm` signed int16 little-endian
- `unix_time_sec` uint32 little-endian
- `sequence` uint8

### スマホ側

`rapidsnark_app` では `収集` タブから次の流れで進めます。

1. ドローン側入力モードを `手入力` または `Raspberry Pi` から選ぶ
2. `Raspberry Pi` モードなら `Raspberry Pi から受信` を押して BLE 広告を受信する
3. 受信した `lat/lon/alt/time` はドローン側ログへ自動反映される
4. 利用者側は `この端末の値を使う` で GPS と気圧センサーを取得する
5. `BLE受信から撮影まで進む` または `端末情報を取得して撮影` を押す
6. 撮影した動画の開始時刻を利用者側ログの時刻として採用する
7. アプリが動画から複数フレームを切り出し、UAV 候補を自動解析する
8. `動画検知で証明実行` または `証明` タブから `Generate And Verify Proof` を押す

必要な権限:

- Android: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION`, `CAMERA`
- iOS: `NSBluetoothAlwaysUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSCameraUsageDescription`

## 動画証拠フロー

このアプリでは、単に BLE テレメトリを受信して証明するのではなく、次の証拠フローを想定している。

1. UAV が BLE で自身の位置・高度・時刻を配信する
2. スマホは `手入力` または BLE 受信でドローン側ログを準備する
3. スマホ自身の GPS / 気圧センサー値を第三者側ログとして取得する
4. アプリのカメラで UAV の映像を動画として記録する
5. 動画の開始時刻を第三者側検知ログの時刻として使う
6. 動画内に UAV が映っていることを確認した場合のみ証明を実行する

現時点では、動画内の UAV 検知は軽量な on-device 画像ラベリングで行っている。保存した動画から複数フレームを切り出し、`drone / quadcopter / airplane / aircraft / helicopter / uav / aerospace engineering` 系ラベルを UAV 候補として扱う。

これはモバイルでまず動かすための軽量実装であり、より高精度にしたい場合は YOLO 系のカスタム TFLite モデルへ差し替えるのが次の段階になる。NanoOWL は Jetson 系向けでスマホ統合が重いため、このアプリでは現時点では採用していない。

## 両方の検知モード

このアプリでは、次の 2 つの機能を両方とも残している。

1. 動画証拠モード
2. ライブ YOLO モード

### 1. 動画証拠モード

- BLE で UAV の位置・高度・時刻を受信する
- スマホ自身の GPS / 気圧センサー値を取得する
- アプリ内カメラで動画を撮影する
- 動画の開始時刻を検知ログの時刻として使う
- 保存した動画から複数フレームを切り出して UAV 候補を解析する
- 検知された場合にゼロ知識証明へ進む

### 2. ライブ YOLO モード

- カメラ映像をその場でリアルタイム解析する
- YOLO TFLite モデルが有効ならそれを優先して利用する
- モデル未配置時は既存のフォールバック検知を維持する
- 画面上で検知ボックスとラベルを確認できる

つまり、動画を証拠として残したいケースにも、その場でリアルタイム確認したいケースにも対応している。

## YOLO 推論パイプライン

アプリには、既存の軽量ラベリングを残したまま、TFLite 化した YOLO モデルへ差し替えられる推論パイプラインを追加している。

- 実装ファイル: `rapidsnark_app/lib/uav_yolo_detector.dart`
- 設定ファイル: `rapidsnark_app/assets/models/uav_yolo_config.json`
- UAV 専用設定ファイル: `rapidsnark_app/assets/models/uav_roboflow_drone_config.json`
- ラベルファイル: `rapidsnark_app/assets/models/uav_detector_labels.txt`

初期状態では `uav_yolo_config.json` の `enabled` が `false` なので、アプリは自動で ML Kit フォールバックを使う。

### YOLO を有効にする手順

1. UAV 検知用に学習または微調整した YOLO モデルを TFLite へ変換する
2. 生成した `.tflite` を `rapidsnark_app/assets/models/uav_yolo11n_uav.tflite` に配置する
3. `rapidsnark_app/assets/models/uav_yolo_config.json` の `enabled` を `true` にする
4. 必要に応じて `score_threshold`, `iou_threshold`, `uses_objectness` を調整する
5. ラベル定義を `uav_detector_labels.txt` に合わせる

### 想定しているモデル形式

現在のパイプラインは、Ultralytics 系でよくある以下の YOLO 出力を想定している。

- `[1, num_features, num_boxes]`
- `[1, num_boxes, num_features]`

また、次のどちらにも対応するようにしている。

- `4 + class_probs` 形式
- `4 + objectness + class_probs` 形式

### Ultralytics での利用イメージ

Ultralytics 公式ドキュメントを前提にすると、UAV データセットで学習したモデルを TFLite へ書き出してアプリへ載せる流れになる。

例:

```bash
yolo export model=best.pt format=tflite imgsz=640
```

参考:

- Ultralytics Docs: https://docs.ultralytics.com/
- TensorFlow Lite Flutter plugin: https://pub.dev/packages/tflite_flutter

## Roboflow Drone Detection TFLITE へ差し替える方向

いちばん現実的な差し替え先として、Roboflow Universe の `Drone Detection TFLITE` 系を想定した専用プロファイルを追加してある。

- 想定設定: `rapidsnark_app/assets/models/uav_roboflow_drone_config.json`
- 想定ラベル: `rapidsnark_app/assets/models/uav_roboflow_drone_labels.txt`
- 想定モデル配置先: `rapidsnark_app/assets/models/uav_roboflow_drone.tflite`

アプリは起動時に次の順でモデルを探す。

1. `uav_roboflow_drone_config.json`
2. `uav_yolo_config.json`
3. どちらも無効または未配置なら ML Kit フォールバック

### 実際の切り替え手順

1. Roboflow 側で `Drone Detection TFLITE` の `.tflite` を取得する
2. `uav_roboflow_drone.tflite` として配置する
3. `uav_roboflow_drone_config.json` の `enabled` を `true` にする
4. 必要に応じて `score_threshold` を調整する

補足:

- 公開ページからそのまま重みが直接取れない場合がある
- Roboflow 側の書き出し条件や API キーが必要になることがある
- そのため、現時点ではアプリ側の受け皿を先に実装し、モデル取得後に差し替える方式にしている

## VisDrone を学習元に使う方向

VisDrone は公式の小物体検知データセットとして非常に有力だが、重要な点として `drone` クラスそのものは含んでいない。そのため、このプロジェクトでは次の方針を採る。

1. VisDrone で小物体検知に強い重みを事前学習する
2. その重みを使って UAV データセットへ fine-tune する
3. fine-tune 後の UAV モデルを TFLite 化してアプリへ載せる

追加したファイル:

- `visdrone/README.md`
- `visdrone/visdrone_det.yaml`
- `scripts/convert_visdrone_det_to_yolo.py`
- `scripts/train_visdrone_yolo.sh`
- `scripts/finetune_uav_from_visdrone.sh`
- `scripts/export_visdrone_tflite.sh`
- `rapidsnark_app/assets/models/uav_visdrone_finetuned_config.json`
- `rapidsnark_app/assets/models/uav_visdrone_finetuned_labels.txt`

アプリ側は起動時に、VisDrone 事前学習後に fine-tune した UAV モデルがあればそれを最優先で読み込むようにしてある。
