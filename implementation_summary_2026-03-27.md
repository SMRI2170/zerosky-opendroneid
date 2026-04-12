# 実装まとめ 2026-03-27

## 概要

このドキュメントは、このワークスペースで実施した以下の作業を時系列と成果物ベースで細かくまとめた記録です。

- 緯度・経度・高度・時間を使った `30m以内` 判定回路の設計
- `Circom` 回路の実装
- `snarkjs` による Groth16 セットアップ
- `circom_witnesscalc` / `flutter_rapidsnark` を使った `rapidsnark_app` への統合
- `.wcd` 生成に必要な環境整備
- Android 実機 `Pixel 8` での起動と証明成功確認
- ユースケース寄り UI への再設計

この記録は「何を作ったか」だけでなく、「どこで詰まり、どう直したか」も残しています。

---

## 1. 目的

当初の要件は以下でした。

- 緯度・経度・高度・時間を入力に使う
- `30m以内` の距離判定を `circom` で書く
- `snarkjs` で Groth16 セットアップする
- `rapidsnark_app` で witness 計算と証明生成を動かす
- 必要な環境も文書化する

その後、追加で以下も対応しました。

- `protobuf` を導入して `.wcd` を実生成
- `Pixel 8` 実機でアプリを起動し、証明成功まで確認
- 技術デモ寄り UI を、研究テーマに近いユースケース寄り UI に改善

---

## 2. 最終的にできたこと

最終的にこのリポジトリでは、以下が動作する状態になりました。

1. `Circom` 回路で「3次元距離が 30m 以下」かつ「時刻差が 5秒以下」を判定
2. `snarkjs` で Groth16 の `.zkey` と verification key を生成
3. `build-circuit` で `circom_witnesscalc` 用 `.wcd` を生成
4. `rapidsnark_app` で
   - 入力値の正規化
   - witness 計算
   - Groth16 証明生成
   - 証明検証
   を実行
5. Android 実機 `Pixel 8` 上でアプリ起動を確認
6. 実機画面で `Proof verified successfully.` と `Verified: true` を確認
7. その後 UI を研究ユースケース向けに再設計

---

## 3. 追加・変更した主なファイル

### 回路・ZK 関連

- `circuits/distance_30m_time.circom`
- `scripts/build_distance_assets.sh`
- `zk-distance/README.md`
- `zk-distance/sample_input.json`

### Flutter アプリ関連

- `rapidsnark_app/lib/main.dart`
- `rapidsnark_app/pubspec.yaml`
- `rapidsnark_app/test/widget_test.dart`

### ドキュメント

- `overview.md`
- `implementation_summary_2026-03-27.md` ← このファイル

### 生成済みアセット

- `rapidsnark_app/assets/distance30.wcd`
- `rapidsnark_app/assets/distance30_groth16.zkey`
- `rapidsnark_app/assets/distance30_verification_key.json`

---

## 4. 実装した回路の仕様

### 入力

回路は以下の 8 つの private input を受け取ります。

- `drone_lat_e7_norm`
- `drone_lon_e7_norm`
- `drone_alt_cm`
- `drone_time_sec`
- `target_lat_e7_norm`
- `target_lon_e7_norm`
- `target_alt_cm`
- `target_time_sec`

### 正規化ルール

- 緯度
  - `lat_e7_norm = round((latitude + 90) * 1e7)`
- 経度
  - `lon_e7_norm = round((longitude + 180) * 1e7)`
- 高度
  - `m -> cm`
- 時刻
  - Unix time sec

### 判定条件

回路では以下の 2 条件を見ます。

1. 3次元距離が `30m` 以下
2. 時刻差が `5秒` 以下

### 公開出力

回路は以下を public output として返します。

- `within30`
- `distance_ok`
- `time_ok`

意味は次のとおりです。

- `within30 = 1`
  - 距離も時刻も閾値内
- `distance_ok = 1`
  - 空間距離のみ閾値内
- `time_ok = 1`
  - 時刻差のみ閾値内

### 距離モデル

回路では球面距離ではなく、近距離判定向けの固定係数近似を使いました。

- 緯度係数: `11132000 cm / degree`
- 経度係数: `9128800 cm / degree`
- 分母: `10000000`

高度差も含めた 3 次元距離の二乗比較で判定しています。

---

## 5. 回路実装で行ったこと

回路は `circuits/distance_30m_time.circom` に実装しました。

### 内部テンプレート

- `Num2Bits`
- `LessThan`
- `LessEqThan`
- `AbsDiff`
- `Distance30mTimeWindow`

### 実装時にぶつかった問題と修正

#### 1. 未初期化 signal エラー

最初の `Num2Bits` 実装では、

- `out[i] * (out[i] - 1) === 0;`

の時点で `out[i]` が未初期化と解釈され、Circom コンパイルが失敗しました。

対策:

- `out[i] <-- (in >> i) & 1;`

を追加してビットを明示的に割り当てました。

#### 2. Non quadratic constraints エラー

最初は以下のような合成式を 1 行で書いていました。

- 絶対値差
- 距離二乗和

これに対して `Non quadratic constraints are not allowed` が発生しました。

対策:

- 中間 signal を切り出して
  - `left_term`
  - `right_term`
  - `lat_sq`
  - `lon_sq`
  - `alt_sq`
  を別々に計算

これで Circom が受け入れる二次制約に分解しました。

#### 3. `.wcd` 側と witness 長が合わない問題

一度は回路コンパイルが通ったものの、`.wcd` から作った witness を `snarkjs groth16 prove` に渡すと

- `Invalid witness length. Circuit: 573, witness: 533`

となりました。

原因:

- `circom` のデフォルト出力では `wires = 573`
- `build-circuit` 側では最適化後 `signals = 533`

でズレていたためです。

対策:

- `circom --O2` でコンパイルするように変更

結果:

- `circom` 側も `wires = 533`
- `.wcd` 側と一致
- witness 長不一致が解消

---

## 6. Groth16 セットアップで行ったこと

`scripts/build_distance_assets.sh` を作成して、以下を自動化しました。

1. `circom --O2 --r1cs --wasm --sym`
2. `snarkjs powersoftau new`
3. `snarkjs powersoftau contribute`
4. `snarkjs powersoftau prepare phase2`
5. `snarkjs groth16 setup`
6. `snarkjs zkey contribute`
7. `snarkjs zkey export verificationkey`
8. `snarkjs wtns calculate`
9. `snarkjs groth16 prove`
10. アプリ assets へのコピー
11. `build-circuit` があれば `.wcd` 生成

### PoT サイズの見直し

最初は `powersoftau new bn128 16` にしていましたが、今回の回路規模では過剰で時間がかかりすぎました。

対策:

- `bn128 12` に変更

これでセットアップ時間を大きく削減しました。

---

## 7. `.wcd` 生成で行ったこと

### 最初の問題

`circom_witnesscalc` を Flutter 側で使うには `.wcd` が必要でしたが、ローカルに `build-circuit` がありませんでした。

### 実施したこと

1. `circom-witnesscalc` リポジトリを取得
2. `build-circuit` をビルド
3. `protobuf` / `protoc` を導入
4. `.wcd` を生成

### `protobuf` 導入

当初 `cargo build --release -p build-circuit` は以下で失敗しました。

- `Could not find protoc`

対策:

- `brew install protobuf`

で `protoc` を導入しました。

### `build-circuit` のバージョン問題

現行 `build-circuit` では `.wcd` は生成できたものの、Flutter 側 `circom_witnesscalc` との互換性が怪しい可能性がありました。

そこで過去バージョンも試しました。

#### 試したもの

- `circom-witnesscalc` 現行版
- `build-circuit/v0.1.1`

#### 問題

`build-circuit/v0.1.1` は `Circom 2.1.9` 世代だったため、最初は

- `pragma circom 2.2.2` 非対応

で失敗しました。

対策:

- 回路 pragma を `2.1.9` に変更

その後、`--O2` で wires 数を一致させることで最終的に整合しました。

### 最終的な方針

- 回路 pragma: `2.1.9`
- `circom --O2`
- `build-circuit v0.1.1`

この組み合わせで

- `.wcd -> witness -> snarkjs groth16 prove -> verify`

まで通る状態になりました。

---

## 8. ローカル検証で確認したこと

### Circom コンパイル成功

最終状態では

- `non-linear constraints: 534`
- `wires: 533`

で正常に生成できました。

### sample witness / proof / verify

`scripts/build_distance_assets.sh` 実行後に以下を確認しました。

- `snarkjs groth16 verify ...`
- 結果: `OK!`

### `.wcd` から witness 計算

`calc-witness` を使って `.wcd` から witness を生成し、

- `snarkjs groth16 prove`
- `snarkjs groth16 verify`

まで通ることを確認しました。

### 公開信号

サンプル入力では最終的に以下になりました。

```json
[
  "1",
  "1",
  "1"
]
```

意味:

- `within30 = 1`
- `distance_ok = 1`
- `time_ok = 1`

---

## 9. Flutter アプリへの統合

最初の `rapidsnark_app` は、既存の最小デモに近い状態でした。

主な問題:

- assets 名と実体が一致していなかった
- witness 計算フローがユースケース向きではなかった
- 単なる `Proof: xx bytes` 表示に近かった

### 追加した処理

`rapidsnark_app/lib/main.dart` で以下を実装しました。

1. 緯度経度高度時刻の入力
2. E7 / cm / sec への正規化
3. `distance30.wcd` 読み込み
4. `CircomWitnesscalc().calculateWitness(...)`
5. `.zkey` をテンポラリへコピー
6. `groth16PublicBufferSize(...)`
7. `groth16Prove(...)`
8. `groth16Verify(...)`
9. 結果表示

### プレースホルダ `.wcd`

最初は `.wcd` 未生成だったため、プレースホルダファイルを置き、

- 実ファイル未生成時は例外文言を出す

形にしていました。

その後、本物の `.wcd` を生成して差し替えました。

---

## 10. UI を技術デモからユースケース寄りへ改善した内容

最初の UI は、

- 座標を直接入力
- 証明を実行
- 生の proof / public signals を見る

という研究者向けの確認画面に近いものでした。

ユーザー要望に応じて、これを「よりユースケースにあったもの」に変更しました。

### 追加したシナリオ

3つのユースケースをプリセットとして実装しました。

#### 1. ラストワンマイル配送

- 住宅街の住民端末
- 配送ルートを開示せず、安全距離だけ確認

#### 2. イベント空撮・警備

- 観客のスマートフォン
- 空撮タイミングと接近判定の検証

#### 3. 紛争解決・監査

- 苦情申立て住民の端末
- 事後検証として「本当に近かったか」だけを示す

### UI 上の変更点

- ヘッダを研究テーマに沿った表現へ変更
  - `UAV SAFETY ZK`
- シナリオカードの追加
- `ドローン側ログ`
- `第三者側検知ログ`
- `住民端末で Generate And Verify Proof`

### 結果表示の意味付け

単なる真偽値ではなく、以下のようにドメイン言語へ変換しました。

- `接近あり: 要注意`
- `安全距離を維持`
- 推定距離
- 時刻差
- プライバシー説明

### ユースケース寄りにした意図

技術デモとしては proof JSON を見せれば足りますが、研究発表・PoC・デモでは

- 誰の端末が
- 何の文脈で
- どの判定を
- どんなプライバシー条件で

出しているかが見えた方が価値が伝わります。

そのため、技術内部よりも「社会実装の場面」を主役にした構成へ寄せました。

---

## 11. テストと静的解析

### `flutter analyze`

実装途中で以下のような指摘がありました。

- 未使用 import
- テストが古い `MyApp` を参照している
- `FilledButton` の import 漏れ

これらを修正し、最終的に

- `flutter analyze`
- 結果: `No issues found!`

を確認しました。

### `flutter test`

ウィジェットテストは最初、文言が複数出るようになったため失敗しました。

失敗内容:

- `都市配送ルートの安全証跡` が 1 つではなく 2 つ見つかった

対策:

- `findsOneWidget` -> `findsWidgets`

へ変更

最終結果:

- `flutter test`
- 結果: `All tests passed!`

---

## 12. Android 実機 `Pixel 8` で行ったこと

### 端末接続確認

以下で確認しました。

- `adb devices`
- `flutter devices`

認識結果:

- `Pixel 8 (mobile) • 45061FDJH0007T • android-arm64`

### アプリ起動

以下で起動しました。

```bash
flutter run -d 45061FDJH0007T
```

初回は Gradle ビルドに時間がかかりましたが、最終的にインストール成功しました。

### ネイティブライブラリ読み込み確認

ログ上で以下を確認しました。

- `libcircomwitnesscalc_module.so`
- `librapidsnark_module.so`

がロードされていました。

### 実機での証明成功確認

UI ダンプとスクリーンショットで、

- `Proof verified successfully.`
- `Verified: true`

を確認しました。

その後、ユースケース寄り UI への変更後も Pixel 8 に再デプロイし、

- 新しいヘッダ
- シナリオカード
- 距離メトリクス

が表示されることを確認しました。

---

## 13. 途中で使った主なコマンド

### 環境確認

```bash
command -v circom
command -v snarkjs
flutter --version
node --version
npm --version
cargo --version
rustc --version
```

### Circom / snarkjs

```bash
circom circuits/distance_30m_time.circom --O2 --r1cs --wasm --sym -o ...
snarkjs powersoftau new bn128 12 ...
snarkjs groth16 setup ...
snarkjs zkey export verificationkey ...
snarkjs wtns calculate ...
snarkjs groth16 prove ...
snarkjs groth16 verify ...
```

### circom-witnesscalc

```bash
git clone https://github.com/iden3/circom-witnesscalc.git /tmp/circom-witnesscalc
cargo build --release -p build-circuit
cargo build --release --bin calc-witness
```

### 過去版 build-circuit

```bash
git clone --branch build-circuit/v0.1.1 https://github.com/iden3/circom-witnesscalc.git /tmp/circom-witnesscalc-v011
cargo build --release -p build-circuit
```

### protobuf

```bash
brew install protobuf
protoc --version
```

### Flutter

```bash
flutter analyze
flutter test
flutter run -d 45061FDJH0007T
```

### Android 端末確認

```bash
adb devices
adb shell uiautomator dump ...
adb exec-out screencap -p > ...
adb logcat -d
adb shell monkey -p com.example.rapidsnark_app -c android.intent.category.LAUNCHER 1
```

---

## 14. 環境として確認できたバージョン

作業中に確認できたものは以下です。

- `circom 2.2.2`
- `snarkjs 0.7.5`
- `Flutter 3.32.5`
- `Dart 3.8.1`
- `node v24.14.0`
- `npm 11.9.0`
- `cargo 1.90.0`
- `rustc 1.90.0`
- `protoc 34.1`

補足:

- 回路 pragma は `2.1.9` に調整しています
- これは `build-circuit v0.1.1` と揃えるためです

---

## 15. この作業で難しかった点

### 1. `.wcd` 生成パイプラインが単純ではなかった

単に `circom` と `snarkjs` が入っていれば終わりではなく、

- `circom_witnesscalc`
- `build-circuit`
- `protoc`
- graph format 互換性

まで見ないと Flutter 実機で動きませんでした。

### 2. R1CS と witness graph のサイズ差

これはかなり重要でした。

- `circom` の最適化状態
- `build-circuit` の最適化状態

がズレると witness 長が合わず、Groth16 証明が失敗します。

### 3. Flutter 実行先の制約

途中では

- macOS target 未構成
- iPhone がオフライン
- adb / simulator の権限制約

があり、最終的に Android 実機 `Pixel 8` が一番確実な確認先になりました。

---

## 16. 現在の到達点

現在は以下の状態です。

- 回路実装済み
- Groth16 セットアップ済み
- `.wcd` 実生成済み
- `rapidsnark_app` に統合済み
- Android 実機で起動済み
- 証明成功確認済み
- ユースケース寄り UI へ改善済み

つまり、単なる「コードだけ置いた」状態ではなく、

- ローカル生成
- witness
- prove
- verify
- Flutter 統合
- Android 実機確認

まで一通りつながった状態です。

---

## 17. まだ改善できる点

今後さらに良くするなら、次の方向があります。

### 1. 成功ケース / 失敗ケースの切り替えを UI 上で明示

今はシナリオごとに preset を切り替えていますが、

- 安全だった例
- 接近していた例

を 1 タップで比較できると、研究デモとしてさらに分かりやすくなります。

### 2. ブロックチェーン送信部分の接続

現時点では

- 端末内証明生成
- ローカル検証

までです。

今後は

- call data 化
- Polygon Amoy 送信
- 検証コントラクト呼び出し

までつなげる余地があります。

### 3. ハッシュ化・Merkle・IPFS を本流へ入れる

今の実装は「距離判定と証明フロー」に絞った PoC です。

研究テーマ全体に寄せるなら、

- Poseidon
- Merkle proof
- IPFS 取得
- 改ざん耐性の説明

まで含めた版に発展させられます。

---

## 18. まとめ

今回の作業で、研究テーマに対して次の段階まで前進しました。

- 「30m以内判定をゼロ知識証明で扱える」ことを回路レベルで実装
- `snarkjs` / `build-circuit` / `rapidsnark` をまたいだ実運用パイプラインを構築
- Android 実機で動くアプリまで統合
- 表示も研究・発表向けにユースケース中心へ改善

重要なのは、単に proof が作れるだけではなく、

- ユースケース
- 端末内完結
- プライバシー保持
- 実機動作

までセットで見せられる状態にしたことです。

このため、今の成果物は PoC としてかなり説明しやすい段階にあります。

