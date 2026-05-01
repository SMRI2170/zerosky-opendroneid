#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <circuit_stem> <sample_input_json> <asset_prefix>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CIRCUIT_BIN="${BUILD_CIRCUIT_BIN:-build-circuit}"

CIRCUIT_STEM="$1"
INPUT_PATH="$2"
ASSET_PREFIX="$3"

CIRCUIT_PATH="$ROOT_DIR/circuits/${CIRCUIT_STEM}.circom"
BUILD_DIR="$ROOT_DIR/zk-distance/build/${CIRCUIT_STEM}"
APP_ASSET_DIR="$ROOT_DIR/rapidsnark_app/assets/circuits/${ASSET_PREFIX}"

mkdir -p "$BUILD_DIR" "$APP_ASSET_DIR"

if [[ ! -f "$CIRCUIT_PATH" ]]; then
  echo "missing circuit: $CIRCUIT_PATH" >&2
  exit 1
fi

if [[ ! -f "$INPUT_PATH" ]]; then
  echo "missing input json: $INPUT_PATH" >&2
  exit 1
fi

echo "[1/8] Compiling ${CIRCUIT_STEM}"
circom "$CIRCUIT_PATH" \
  --O2 \
  --r1cs \
  --wasm \
  --sym \
  -l "$ROOT_DIR/node_modules" \
  -o "$BUILD_DIR"

echo "[2/8] Preparing Powers of Tau"
snarkjs powersoftau new bn128 12 "$BUILD_DIR/pot12_0000.ptau" -v
snarkjs powersoftau contribute "$BUILD_DIR/pot12_0000.ptau" "$BUILD_DIR/pot12_0001.ptau" \
  --name="${ASSET_PREFIX} contribution" \
  -e="${ASSET_PREFIX} deterministic contribution"
snarkjs powersoftau prepare phase2 "$BUILD_DIR/pot12_0001.ptau" "$BUILD_DIR/pot12_final.ptau"

echo "[3/8] Running Groth16 setup"
snarkjs groth16 setup \
  "$BUILD_DIR/${CIRCUIT_STEM}.r1cs" \
  "$BUILD_DIR/pot12_final.ptau" \
  "$BUILD_DIR/${ASSET_PREFIX}_groth16_0000.zkey"

echo "[4/8] Contributing to zkey"
snarkjs zkey contribute \
  "$BUILD_DIR/${ASSET_PREFIX}_groth16_0000.zkey" \
  "$BUILD_DIR/${ASSET_PREFIX}_groth16.zkey" \
  --name="${ASSET_PREFIX} zkey contribution" \
  -e="${ASSET_PREFIX} zkey deterministic contribution"

echo "[5/8] Exporting verification key"
snarkjs zkey export verificationkey \
  "$BUILD_DIR/${ASSET_PREFIX}_groth16.zkey" \
  "$BUILD_DIR/${ASSET_PREFIX}_verification_key.json"

echo "[6/8] Calculating sample witness"
snarkjs wtns calculate \
  "$BUILD_DIR/${CIRCUIT_STEM}_js/${CIRCUIT_STEM}.wasm" \
  "$INPUT_PATH" \
  "$BUILD_DIR/${ASSET_PREFIX}_sample.wtns"

echo "[7/8] Generating sample proof"
snarkjs groth16 prove \
  "$BUILD_DIR/${ASSET_PREFIX}_groth16.zkey" \
  "$BUILD_DIR/${ASSET_PREFIX}_sample.wtns" \
  "$BUILD_DIR/${ASSET_PREFIX}_proof.json" \
  "$BUILD_DIR/${ASSET_PREFIX}_public.json"

echo "[8/8] Copying artifacts for rapidsnark_app"
cp "$BUILD_DIR/${ASSET_PREFIX}_groth16.zkey" "$APP_ASSET_DIR/${ASSET_PREFIX}_groth16.zkey"
cp "$BUILD_DIR/${ASSET_PREFIX}_verification_key.json" "$APP_ASSET_DIR/${ASSET_PREFIX}_verification_key.json"

if command -v "$BUILD_CIRCUIT_BIN" >/dev/null 2>&1; then
  echo "Generating .wcd with build-circuit"
  "$BUILD_CIRCUIT_BIN" \
    "$CIRCUIT_PATH" \
    "$APP_ASSET_DIR/${ASSET_PREFIX}.wcd"
else
  echo "Skipping .wcd generation because build-circuit is not installed."
  echo "Set BUILD_CIRCUIT_BIN or install build-circuit, then re-run this script to create ${APP_ASSET_DIR}/${ASSET_PREFIX}.wcd"
fi

echo "Done. Artifacts are in $BUILD_DIR and app assets are updated in $APP_ASSET_DIR."
