#!/bin/zsh
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <visdrone_pretrained_best.pt> <uav_dataset_yaml>"
  exit 1
fi

PRETRAINED_PT="$1"
UAV_DATASET_YAML="$2"

if [[ ! -f "$PRETRAINED_PT" ]]; then
  echo "Pretrained weights not found: $PRETRAINED_PT"
  exit 1
fi

if [[ ! -f "$UAV_DATASET_YAML" ]]; then
  echo "UAV dataset yaml not found: $UAV_DATASET_YAML"
  exit 1
fi

yolo detect train \
  model="$PRETRAINED_PT" \
  data="$UAV_DATASET_YAML" \
  imgsz=640 \
  epochs=60 \
  batch=8 \
  workers=4 \
  device=cpu \
  project=uav_runs \
  name=uav_from_visdrone
