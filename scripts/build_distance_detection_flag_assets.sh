#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/build_distance_variant_assets.sh" \
  distance_30m_time_detection_flag \
  "$ROOT_DIR/zk-distance/samples/sample_input_detection_flag.json" \
  distance30_detection_flag
