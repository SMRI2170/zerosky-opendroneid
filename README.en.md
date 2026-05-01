*Read this in other languages: [English](README.en.md), [日本語](README.md).*

# zk-UAV-Proximity-Proof (formerly: zkp-m1)

This is a demonstration project that uses drone location data and user device sensor data to prove that the drone is `within 30 meters and within a 5-second time window` using Zero-Knowledge Proofs (ZKP).

<p float="left">
  <img src="images/tflite-model-drone-detection.jpg" width="300" alt="TFLite Model Drone Detection" />
  <img src="images/opendroneid-detection-log.jpg" width="300" alt="OpenDroneID Detection Log" />
  <img src="images/experimental-drone.jpg" width="300" alt="Experimental Drone" />
  <img src="images/google-ml-kit-drone-detection.jpg" width="300" alt="Google ML Kit Drone Detection" />
  <img src="images/before-remoteID-detection.jpg" width="300" alt="Before RemoteID Detection" />
  <img src="images/after-remoteID-detection.jpg" width="300" alt="After RemoteID Detection" />
</p>

This repository contains the following three main components:

- `circuits/` and `zk-distance/`: Circom circuits, Groth16 artifacts, and optimization comparisons.
- `rapidsnark_app/`: A Flutter application for Android.
- `uav/remote_id.py`: A script for sending BLE telemetry from a Raspberry Pi.

## Repository Structure

- `circuits/distance_30m_time.circom`
  - A circuit that outputs `within30`, `distance_ok`, and `time_ok` from location and time inputs.
- `circuits/distance_30m_time_series.circom` etc.
  - Extended circuits that handle time-series location data across multiple timestamps, and combine object detection flags or model inference commitments.
- `scripts/build_distance_assets.sh` etc.
  - Scripts for compiling circuits, generating Groth16 setups, and updating assets for the app (supports various circuit variants).
- `scripts/compare_circom_optimizations.sh`
  - Comparison of `--O0 / --O1 / --O2` compiler optimization flags.
- `scripts/compare_distance_variant_constraints.sh`
  - Generates a CSV comparing constraints across different circuit variants.
- `scripts/train_visdrone_yolo.sh`, `convert_visdrone_det_to_yolo.py` etc.
  - ML-focused scripts for YOLO model training, format conversion from VisDrone, and exporting to TFLite.
- `scripts/generate_project_summary_slides.py`
  - Script to automatically generate a PowerPoint (pptx) slide summarizing the project.
- `zk-distance/sample_input.json`
  - Sample input for the circuits.
- `rapidsnark_app/lib/main.dart`
  - The main Flutter demonstration app (executes drone detection internally using a YOLO model).
- `uav/remote_id.py`
  - Transmits BLE manufacturer data from a Raspberry Pi.
- `uav/OPENDRONEID_IMPLEMENTATION.md`, `SENSOR_INTEGRATION.md` etc.
  - Documentation detailing the OpenDroneID (ASTM F3411-22a) implementation and integration of physical sensors (GPS, BME280) on the Raspberry Pi.
- `visdrone/`
  - Configuration files for YOLO pre-training and fine-tuning aimed at small object detection of UAVs (drones).

## Requirements

At a minimum, you will need the following installed:

- `circom`
- `snarkjs`
- `node`
- `cargo` / `rustc`
- `Flutter`
- An Android device

The primary versions tested in this repository can be found in [zk-distance/README.md](zk-distance/README.md).

## 1. Generate Circuit Artifacts

First, compile the circuits and generate the required proving artifacts.

```bash
./scripts/build_distance_assets.sh
```

This script will perform the following steps:

- Compile the Circom circuit using `O2` optimization.
- Execute the Powers of Tau and Groth16 setup phases.
- Generate sample witness, proof, and public signals.
- Update the `zkey` and `verification key` used by the app.
- If `build-circuit` is available, generate a `.wcd` file.

To set up `build-circuit` manually:

```bash
git clone https://github.com/iden3/circom-witnesscalc.git /tmp/circom-witnesscalc
cd /tmp/circom-witnesscalc
cargo build --release -p build-circuit
BUILD_CIRCUIT_BIN=/tmp/circom-witnesscalc/target/release/build-circuit ./scripts/build_distance_assets.sh
```

## 2. Start the Raspberry Pi side

On the Raspberry Pi, [remote_id.py](uav/remote_id.py) will start sending BLE advertisements.

Example of sending fixed values:

```bash
python3 uav/remote_id.py --lat 35.6891390 --lon 139.6917000 --alt 12.0
```

Example of sending from a JSON file:

```bash
python3 uav/remote_id.py --json-path uav_sample.json
```

Transmission payload specification:

- `company_id = 0x02E5`
- `magic = 0x5A`
- `version = 0x01`
- `lat_e7` signed int32 little-endian
- `lon_e7` signed int32 little-endian
- `altitude_dm` signed int16 little-endian
- `unix_time_sec` uint32 little-endian
- `sequence` uint8

Notes:

- Bluetooth-related tools are required on the Pi, as the script uses `hciconfig` / `hcitool`.
- The script uses `sudo` internally, so execute permissions or sudo access is required.

## 3. Launch the App

```bash
cd rapidsnark_app
flutter pub get
flutter run
```

### Required App Permissions

- Android
  - `BLUETOOTH_SCAN`
  - `BLUETOOTH_CONNECT`
  - `ACCESS_FINE_LOCATION`
  - `CAMERA`
- iOS
  - `NSBluetoothAlwaysUsageDescription`
  - `NSLocationWhenInUseUsageDescription`
  - `NSCameraUsageDescription`

### Current Input Methods

In the app's "Collect" (`収集`) tab, drone logs can be inputted in two ways:

- `Manual Input` (`手入力`)
- `Raspberry Pi BLE Reception` (`Raspberry Pi BLE 受信`)

User logs are obtained from the smartphone's GPS and barometer sensors.

## 4. Demonstration Steps

The recommended procedure for a live demonstration is as follows:

1. Start the BLE telemetry transmission on the Raspberry Pi.
2. Select the drone input mode in the app's "Collect" tab.
3. If in `Raspberry Pi` mode, press "Receive from Raspberry Pi" (`Raspberry Pi から受信`).
4. Obtain the user logs by pressing "Use this device's values" (`この端末の値を使う`).
5. Press "Proceed to capture from BLE reception" (`BLE受信から撮影まで進む`) or "Capture after getting device info" (`端末情報を取得して撮影`).
6. Once a UAV candidate is detected via video analysis, proceed to "Execute proof with video detection" (`動画検知で証明実行`) or go to the "Proof" (`証明`) tab.
7. Check the `Public Signals` and the verification results.

## 5. Current Highlights

- The circuit simultaneously verifies `within 30 meters` and `within 5 seconds`.
- Witness calculation, Groth16 proving, and verification are all completed locally within the app.
- The app can receive BLE advertisements directly from the Raspberry Pi.
- Real-time drone image recognition using a YOLO model pre-trained and fine-tuned on VisDrone.
- Generation of OpenDroneID-compliant BLE advertisement packets and integration with physical GPS/barometer sensors.
- Includes a comparison report of `--O0 / --O1 / --O2` optimizations.
- Capable of generating CSV constraint comparisons across different circuit variants.

## Related Documentation

- [zk-distance/README.md](zk-distance/README.md)
- [rapidsnark_app/README.md](rapidsnark_app/README.md)
- [optimization_report.md](zk-distance/optimization-compare/optimization_report.md)
- [visdrone/README.md](visdrone/README.md)
- [uav/OPENDRONEID_IMPLEMENTATION.md](uav/OPENDRONEID_IMPLEMENTATION.md)
- [uav/OPENDRONEID_COMPLIANCE_LOG.md](uav/OPENDRONEID_COMPLIANCE_LOG.md)
- [uav/SENSOR_INTEGRATION.md](uav/SENSOR_INTEGRATION.md)