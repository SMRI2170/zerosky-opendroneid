#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/zk-distance/build"
APP_ASSETS_DIR="$ROOT_DIR/rapidsnark_app/assets"
CIRCUIT_PATH="$ROOT_DIR/circuits/distance_30m_time.circom"
INPUT_PATH="$ROOT_DIR/zk-distance/sample_input.json"
BUILD_CIRCUIT_BIN="${BUILD_CIRCUIT_BIN:-build-circuit}"

mkdir -p "$BUILD_DIR"

echo "[1/8] Compiling circom circuit"
circom "$CIRCUIT_PATH" \
  --O2 \
  --r1cs \
  --wasm \
  --sym \
  -o "$BUILD_DIR"

echo "[2/8] Preparing Powers of Tau"
snarkjs powersoftau new bn128 12 "$BUILD_DIR/pot12_0000.ptau" -v
snarkjs powersoftau contribute "$BUILD_DIR/pot12_0000.ptau" "$BUILD_DIR/pot12_0001.ptau" \
  --name="distance30 contribution" \
  -e="distance30 deterministic contribution"
snarkjs powersoftau prepare phase2 "$BUILD_DIR/pot12_0001.ptau" "$BUILD_DIR/pot12_final.ptau"

echo "[3/8] Running Groth16 setup"
snarkjs groth16 setup \
  "$BUILD_DIR/distance_30m_time.r1cs" \
  "$BUILD_DIR/pot12_final.ptau" \
  "$BUILD_DIR/distance30_groth16_0000.zkey"

echo "[4/8] Contributing to zkey"
snarkjs zkey contribute \
  "$BUILD_DIR/distance30_groth16_0000.zkey" \
  "$BUILD_DIR/distance30_groth16.zkey" \
  --name="distance30 zkey contribution" \
  -e="distance30 zkey deterministic contribution"

echo "[5/8] Exporting verification key"
snarkjs zkey export verificationkey \
  "$BUILD_DIR/distance30_groth16.zkey" \
  "$BUILD_DIR/distance30_verification_key.json"

echo "[6/8] Calculating sample witness"
snarkjs wtns calculate \
  "$BUILD_DIR/distance_30m_time_js/distance_30m_time.wasm" \
  "$INPUT_PATH" \
  "$BUILD_DIR/distance30_sample.wtns"

echo "[7/8] Generating sample proof"
snarkjs groth16 prove \
  "$BUILD_DIR/distance30_groth16.zkey" \
  "$BUILD_DIR/distance30_sample.wtns" \
  "$BUILD_DIR/distance30_proof.json" \
  "$BUILD_DIR/distance30_public.json"

echo "[8/8] Copying artifacts for rapidsnark_app"
cp "$BUILD_DIR/distance30_groth16.zkey" "$APP_ASSETS_DIR/distance30_groth16.zkey"
cp "$BUILD_DIR/distance30_verification_key.json" "$APP_ASSETS_DIR/distance30_verification_key.json"

if command -v "$BUILD_CIRCUIT_BIN" >/dev/null 2>&1; then
  echo "Generating .wcd with build-circuit"
  "$BUILD_CIRCUIT_BIN" \
    "$CIRCUIT_PATH" \
    "$APP_ASSETS_DIR/distance30.wcd"
else
  echo "Skipping .wcd generation because build-circuit is not installed."
  echo "Set BUILD_CIRCUIT_BIN or install build-circuit, then re-run this script to create rapidsnark_app/assets/distance30.wcd"
fi

echo "Done. Artifacts are in $BUILD_DIR and app assets are updated."
