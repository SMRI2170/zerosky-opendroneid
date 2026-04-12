# VisDrone Pipeline

このディレクトリは、VisDrone を学習元として使い、最終的に UAV 検知モデルへつなぐための下準備をまとめたものです。

## 重要

VisDrone の公式 DET クラスには `drone` は含まれていません。

VisDrone の主な 10 クラス:

- pedestrian
- person
- bicycle
- car
- van
- truck
- bus
- motor
- awning-tricycle
- tricycle

そのため、このプロジェクトでは VisDrone を次の目的で使います。

1. 小物体検知に強い重みを事前学習する
2. その重みを出発点にして UAV クラスへ fine-tune する
3. fine-tune 後の UAV モデルを TFLite 化してアプリへ載せる

## 想定ワークフロー

1. 公式 VisDrone2019-DET をダウンロードする
2. `scripts/convert_visdrone_det_to_yolo.py` で YOLO 形式へ変換する
3. `scripts/train_visdrone_yolo.sh` で VisDrone 事前学習を行う
4. 別途 UAV データセットで fine-tune する
5. `scripts/export_visdrone_tflite.sh` で TFLite 化する
6. `rapidsnark_app/assets/models/uav_visdrone_finetuned.tflite` に配置する

## `drone` を検知するために必要なもの

VisDrone だけでは `drone` クラスは学習できません。`drone` を実際に検知したい場合は、VisDrone 事前学習済みの重みを使って、`drone` 単一クラスの YOLO データセットで fine-tune します。

このリポジトリではそのための雛形として、次を用意しています。

- `visdrone/uav_drone_single_class.yaml`
- `scripts/finetune_uav_from_visdrone.sh`

想定するデータセット構成:

```text
visdrone/uav_drone_yolo/
  train/
    images/
    labels/
  val/
    images/
    labels/
```

ラベルは YOLO 形式の単一クラスで、すべて `0` を `drone` として扱います。

例:

```bash
scripts/finetune_uav_from_visdrone.sh \
  runs/detect/visdrone_runs/visdrone_pretrain3/weights/best.pt \
  visdrone/uav_drone_single_class.yaml
```

## 必要ツール

- Python 3.10+
- `ultralytics`
- `PyYAML`

例:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install ultralytics pyyaml
```

## 公式参照

- VisDrone Organization: https://github.com/VisDrone
- VisDrone Dataset Repo: https://github.com/VisDrone/VisDrone-Dataset
- Ultralytics Docs: https://docs.ultralytics.com/
