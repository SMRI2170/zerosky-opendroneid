#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CIRCUIT_PATH="$ROOT_DIR/circuits/distance_30m_time.circom"
OUT_BASE="${1:-$ROOT_DIR/zk-distance/optimization-compare}"

mkdir -p "$OUT_BASE"

if ! command -v circom >/dev/null 2>&1; then
  echo "circom is required but was not found in PATH" >&2
  exit 1
fi

if ! command -v snarkjs >/dev/null 2>&1; then
  echo "snarkjs is required but was not found in PATH" >&2
  exit 1
fi

extract_metric() {
  local label="$1"
  local file="$2"
  perl -pe 's/\e\[[0-9;]*m//g' "$file" \
    | sed -E 's/^\[INFO\][[:space:]]+snarkJS: //' \
    | awk -F': ' -v key="$label" '$1 == key {print $2}' \
    | tail -n 1
}

echo "optimization,constraints,wires,private_inputs,public_inputs,public_outputs,labels,r1cs_bytes,wasm_bytes,sym_bytes,substitutions" \
  > "$OUT_BASE/summary.csv"

for opt in O0 O1 O2; do
  out_dir="$OUT_BASE/$opt"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  echo "=== Compiling with --$opt ==="
  circom "$CIRCUIT_PATH" \
    --"$opt" \
    --r1cs \
    --wasm \
    --sym \
    --inspect \
    --simplification_substitution \
    -o "$out_dir" \
    2>&1 | tee "$out_dir/compile.log"

  snarkjs r1cs info "$out_dir/distance_30m_time.r1cs" \
    | tee "$out_dir/r1cs_info.txt"

  constraints="$(extract_metric "# of Constraints" "$out_dir/r1cs_info.txt")"
  wires="$(extract_metric "# of Wires" "$out_dir/r1cs_info.txt")"
  private_inputs="$(extract_metric "# of Private Inputs" "$out_dir/r1cs_info.txt")"
  public_inputs="$(extract_metric "# of Public Inputs" "$out_dir/r1cs_info.txt")"
  public_outputs="$(extract_metric "# of Outputs" "$out_dir/r1cs_info.txt")"
  labels="$(extract_metric "# of Labels" "$out_dir/r1cs_info.txt")"

  r1cs_bytes="$(wc -c < "$out_dir/distance_30m_time.r1cs" | tr -d ' ')"
  wasm_bytes="$(wc -c < "$out_dir/distance_30m_time_js/distance_30m_time.wasm" | tr -d ' ')"
  sym_bytes="$(wc -c < "$out_dir/distance_30m_time.sym" | tr -d ' ')"

  substitutions_file="$out_dir/distance_30m_time_substitutions.json"
  substitutions="0"
  if [[ -f "$substitutions_file" ]]; then
    substitutions="$(jq 'length' "$substitutions_file")"
  fi

  echo "$opt,$constraints,$wires,$private_inputs,$public_inputs,$public_outputs,$labels,$r1cs_bytes,$wasm_bytes,$sym_bytes,$substitutions" \
    >> "$OUT_BASE/summary.csv"
done

echo
echo "Summary"
column -s, -t "$OUT_BASE/summary.csv"
echo
echo "Artifacts written to $OUT_BASE"
