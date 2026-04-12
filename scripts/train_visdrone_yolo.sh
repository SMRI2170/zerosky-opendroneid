#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <visdrone_yolo_root> [model]"
  exit 1
fi

VISDRONE_YOLO_ROOT="$1"
BASE_MODEL="${2:-yolov8n.pt}"
SCRIPT_DIR="${0:A:h}"
DATA_FILE="${SCRIPT_DIR:h}/visdrone/visdrone_det.yaml"

if [[ ! -f "$DATA_FILE" ]]; then
  echo "Dataset yaml not found: $DATA_FILE"
  exit 1
fi

yolo detect train \
  model="$BASE_MODEL" \
  data="$DATA_FILE" \
  imgsz=640 \
  epochs=80 \
  batch=8 \
  workers=4 \
  device=cpu \
  project=visdrone_runs \
  name=visdrone_pretrain
