#!/bin/zsh
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <best.pt> [output_tflite]"
  exit 1
fi

BEST_PT="$1"
OUTPUT_TFLITE="${2:-/Users/smri/Downloads/cursor/m1/rapidsnark_app/assets/models/uav_visdrone_finetuned.tflite}"

yolo export model="$BEST_PT" format=tflite imgsz=640

EXPORTED_DIR="${BEST_PT:r}_saved_model"
EXPORTED_TFLITE="${BEST_PT:r}_saved_model/${BEST_PT:t:r}_float32.tflite"

if [[ ! -f "$EXPORTED_TFLITE" ]]; then
  echo "Exported TFLite not found: $EXPORTED_TFLITE"
  exit 1
fi

cp "$EXPORTED_TFLITE" "$OUTPUT_TFLITE"
echo "Copied $EXPORTED_TFLITE to $OUTPUT_TFLITE"
