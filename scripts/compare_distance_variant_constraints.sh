#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/zk-distance/constraint-compare"
TMP_DIR="$OUT_DIR/tmp"

mkdir -p "$OUT_DIR" "$TMP_DIR"

python3 - <<PY
from pathlib import Path
import csv
import re
import subprocess

root = Path("${ROOT_DIR}")
out_dir = Path("${OUT_DIR}")
tmp_dir = Path("${TMP_DIR}")

circuits = [
    ("distance_30m_time", "base"),
    ("distance_30m_time_detection_flag", "detection_flag"),
    ("distance_30m_time_detection_commitment", "detection_commitment"),
    ("distance_30m_time_feature_classifier", "feature_classifier"),
]

def pick(text: str, label: str) -> str:
    match = re.search(rf"(?m)^{re.escape(label)}: ([0-9]+)", text)
    return match.group(1) if match else ""

rows = []
for circuit, profile in circuits:
    result = subprocess.run(
        [
            "circom",
            str(root / "circuits" / f"{circuit}.circom"),
            "--r1cs",
            "--sym",
            "-o",
            str(tmp_dir),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    text = result.stdout
    rows.append({
        "circuit": circuit,
        "profile": profile,
        "non_linear_constraints": pick(text, "non-linear constraints"),
        "linear_constraints": pick(text, "linear constraints"),
        "private_inputs": pick(text, "private inputs"),
        "public_outputs": pick(text, "public outputs"),
        "wires": pick(text, "wires"),
        "labels": pick(text, "labels"),
    })

with (out_dir / "summary.csv").open("w", newline="") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=[
            "circuit",
            "profile",
            "non_linear_constraints",
            "linear_constraints",
            "private_inputs",
            "public_outputs",
            "wires",
            "labels",
        ],
    )
    writer.writeheader()
    writer.writerows(rows)

print(f"Wrote {out_dir / 'summary.csv'}")
PY
