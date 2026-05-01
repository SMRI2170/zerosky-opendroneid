import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:circom_witnesscalc/circom_witnesscalc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rapidsnark/flutter_rapidsnark.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as video_thumbnail;

import 'uav_yolo_detector.dart';

List<CameraDescription> _availableCameras = [];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // カメラリスト取得は initState 側で行うため、ここでは空リストのまま起動する
  // （パーミッション未付与時に availableCameras() が例外を起こしても問題なし）
  try {
    _availableCameras = await availableCameras();
  } catch (_) {}
  runApp(const RapidsnarkApp());
}

class RapidsnarkApp extends StatelessWidget {
  const RapidsnarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UAV Safety Proof Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B6E69),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF3F2EA),
        useMaterial3: true,
      ),
      home: const SafetyUseCasePage(),
    );
  }
}

class PositionSnapshot {
  const PositionSnapshot({
    required this.lat,
    required this.lon,
    required this.alt,
    required this.unixTimeSec,
  });
  final double lat;
  final double lon;
  final double alt;
  final int unixTimeSec;
}

class VideoEvidence {
  const VideoEvidence({
    required this.path,
    required this.recordRequestedAt,
    required this.recordCompletedAt,
    required this.detectionSource,
  });

  final String path;
  final DateTime recordRequestedAt;
  final DateTime recordCompletedAt;
  final String detectionSource;
}

class SampledVideoFrame {
  const SampledVideoFrame({required this.path, required this.timeMs});

  final String path;
  final int timeMs;
}

class VideoDetectionDetail {
  const VideoDetectionDetail({
    required this.timeMs,
    required this.backend,
    required this.labels,
    this.previewPath,
    this.regions = const [],
  });

  final int timeMs;
  final String backend;
  final List<String> labels;
  final String? previewPath;
  final List<VideoDetectedRegion> regions;
}

class VideoDetectedRegion {
  const VideoDetectedRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.label,
    required this.confidence,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final String label;
  final double confidence;
}

enum DroneInputMode { manual, ble }

enum SafetyCircuitProfile {
  base,
  detectionFlag,
  detectionCommitment,
  featureClassifier,
  timeSeries,
}

class SafetyCircuitConfig {
  const SafetyCircuitConfig({
    required this.profile,
    required this.label,
    required this.assetPrefix,
    required this.description,
    this.requiresVideo = false,
  });

  final SafetyCircuitProfile profile;
  final String label;
  final String assetPrefix;
  final String description;
  final bool requiresVideo;
}

// ── OpenDroneID パケット (ASTM F3411-22a / opendroneid-core-c 準拠) ───────────
//
// BLE Service UUID 0xFFFA の Service Data AD から解析する。
// remote_id.py が BasicID (偶数 seq) と Location (奇数 seq) を交互に送信するため、
// スキャナーは Location メッセージを見つけ次第フォームに反映する。
//
// Location メッセージ (25 bytes) — opendroneid-core-c ODID_Location_encoded_t:
//   Byte 0    : (MessageType=1 << 4) | ProtoVersion
//   Byte 1    : Status[7:4] | Reserved[3] | HeightType[2] | EWDirection[1] | SpeedMult[0]
//                 Status high nibble: UNDECLARED=0, GROUND=1, AIRBORNE=2, EMERGENCY=3, RC_LOST=4
//                 EWDirection=1 → direction = raw + 180 (West half)
//                 SpeedMult=1  → speed_h = raw * 0.75 m/s (high domain)
//                 SpeedMult=0  → speed_h = raw * 0.25 m/s (low domain)
//   Byte 2    : Direction (uint8, 0-179 or 0-179+EWDir)
//   Byte 3    : SpeedHorizontal (uint8, ÷0.25 or ÷0.75 per SpeedMult)
//   Byte 4    : SpeedVertical (int8, ÷0.5 m/s, positive=up)
//   Bytes 5-8 : Latitude  (int32 LE, × 1e-7 degrees)
//   Bytes 9-12: Longitude (int32 LE, × 1e-7 degrees)
//   Bytes 13-14: AltitudeBaro (uint16 LE, raw=(alt+1000)/0.5, step=0.5m)
//   Bytes 15-16: AltitudeGeo  (uint16 LE, same encoding)
//   Bytes 17-18: Height      (uint16 LE, same encoding)
//   Byte 19   : HorizAcc[3:0] | VertAcc[7:4]
//   Byte 20   : BaroAcc[3:0]  | SpeedAcc[7:4]
//   Bytes 21-22: Timestamp (uint16 LE, 1/10 sec since UTC hour start)
//   Byte 23   : TSAcc[3:0] | Reserved[7:4]
//   Byte 24   : Reserved
//
// BasicID メッセージ (25 bytes) — opendroneid-core-c ODID_BasicID_encoded_t:
//   Byte 0    : (MessageType=0 << 4) | ProtoVersion
//   Byte 1    : (IDType << 4) | UAType  — IDType high nibble, UAType low nibble
//   Bytes 2-21: UAS_ID (20 bytes, null-padded ASCII or binary)
//   Bytes 22-24: Reserved
class UavTelemetryPacket {
  const UavTelemetryPacket({
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.altitudeGeoMeters,
    required this.speedH,
    required this.speedV,
    required this.direction,
    required this.statusIsAirborne,
    required this.unixTimeSec,
    required this.sequence,
    this.uasId,
  });

  // OpenDroneID BLE Service UUID (16-bit: 0xFFFA)
  static const serviceUuid = '0000fffa-0000-1000-8000-00805f9b34fb';

  // opendroneid-core-c ODID_MsgType_t
  static const _msgTypeBasicId  = 0;
  static const _msgTypeLocation = 1;

  // opendroneid-core-c ODID_Status_t (UNDECLARED=0, GROUND=1, AIRBORNE=2, EMERGENCY=3, RC_LOST=4)
  static const _statusAirborne = 2;

  final double latitude;
  final double longitude;
  final double altitudeMeters;     // AltitudeBaro (QFE, BME280)
  final double altitudeGeoMeters;  // AltitudeGeo (GPS WGS84)
  final double speedH;             // 水平速度 m/s
  final double speedV;             // 垂直速度 m/s (正=上昇)
  final double direction;          // 進行方向 degrees (0-359)
  final bool statusIsAirborne;     // Status == AIRBORNE
  final int unixTimeSec;
  final int sequence;
  final String? uasId;

  // opendroneid-core-c 高度エンコード: raw = (alt_m + 1000) / 0.5
  // デコード: alt_m = raw * 0.5 - 1000
  static double _decodeAltitude(int raw) {
    if (raw == 0xFFFF) return 0.0;
    return raw * 0.5 - 1000.0;
  }

  // opendroneid-core-c 方向デコード: EWDirection フラグで西半球補正
  static double _decodeDirection(int raw, int ewDir) {
    return ewDir == 1 ? raw + 180.0 : raw.toDouble();
  }

  // opendroneid-core-c 水平速度デコード: SpeedMult フラグで高域スケール切替
  static double _decodeSpeedH(int raw, int speedMult) {
    return speedMult == 1 ? raw * 0.75 : raw * 0.25;
  }

  // opendroneid-core-c 垂直速度デコード: int8 × 0.5 m/s
  static double _decodeSpeedV(int raw) {
    final signed = raw >= 128 ? raw - 256 : raw;
    return signed * 0.5;
  }

  // タイムスタンプ再構築: 1/10 秒単位の時間内秒数 → Unix 秒
  static int _reconstructUnixTime(int tsRaw) {
    if (tsRaw == 0xFFFF) return DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final secondsWithinHour = tsRaw ~/ 10;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hourStart = nowSec - (nowSec % 3600);
    return hourStart + secondsWithinHour;
  }

  /// Location メッセージ (type=1) をパースしてパケットを返す。
  /// Service Data の値部分（UUID を除く 25 バイト）を受け取る。
  static UavTelemetryPacket? tryParseLocation(List<int>? rawBytes, int seq) {
    if (rawBytes == null || rawBytes.length < 25) return null;
    final msgType = (rawBytes[0] >> 4) & 0x0F;
    if (msgType != _msgTypeLocation) return null;

    // Byte 1: Status[7:4] | Reserved[3] | HeightType[2] | EWDirection[1] | SpeedMult[0]
    final byte1     = rawBytes[1] & 0xFF;
    final status    = (byte1 >> 4) & 0x0F;
    final ewDir     = (byte1 >> 1) & 0x01;
    final speedMult = byte1 & 0x01;

    final data = ByteData.sublistView(Uint8List.fromList(rawBytes));
    final latI32   = data.getInt32(5,  Endian.little);
    final lonI32   = data.getInt32(9,  Endian.little);
    final altBaro  = data.getUint16(13, Endian.little);
    final altGeo   = data.getUint16(15, Endian.little);
    final tsRaw    = data.getUint16(21, Endian.little);

    if (latI32 == 0 && lonI32 == 0) return null; // 無効座標

    return UavTelemetryPacket(
      latitude:         latI32 / 1e7,
      longitude:        lonI32 / 1e7,
      altitudeMeters:   _decodeAltitude(altBaro),
      altitudeGeoMeters: _decodeAltitude(altGeo),
      speedH:           _decodeSpeedH(rawBytes[3] & 0xFF, speedMult),
      speedV:           _decodeSpeedV(rawBytes[4] & 0xFF),
      direction:        _decodeDirection(rawBytes[2] & 0xFF, ewDir),
      statusIsAirborne: status == _statusAirborne,
      unixTimeSec:      _reconstructUnixTime(tsRaw),
      sequence:         seq,
    );
  }

  /// BasicID メッセージ (type=0) から UAS_ID 文字列と IDType/UAType を取り出す。
  static String? tryParseUasId(List<int>? rawBytes) {
    if (rawBytes == null || rawBytes.length < 25) return null;
    final msgType = (rawBytes[0] >> 4) & 0x0F;
    if (msgType != _msgTypeBasicId) return null;

    // Byte 1: (IDType << 4) | UAType — high nibble=IDType, low nibble=UAType

    final idBytes = rawBytes.sublist(2, 22);
    final nullIdx = idBytes.indexOf(0);
    return String.fromCharCodes(nullIdx >= 0 ? idBytes.sublist(0, nullIdx) : idBytes)
        .trim()
        .replaceAll('\x00', '');
  }

  /// Service Data マップから OpenDroneID の値を取り出すヘルパー。
  /// flutter_blue_plus は Guid キーを 128-bit 形式で返すため、0xFFFA を含む
  /// エントリを大文字・小文字問わず探す。
  static List<int>? extractFromServiceData(Map<dynamic, List<int>> serviceData) {
    for (final entry in serviceData.entries) {
      final key = entry.key.toString().toLowerCase();
      if (key.contains('fffa')) return entry.value;
    }
    return null;
  }
}

class SafetyUseCasePage extends StatefulWidget {
  const SafetyUseCasePage({super.key});

  @override
  State<SafetyUseCasePage> createState() => _SafetyUseCasePageState();
}

class _SafetyUseCasePageState extends State<SafetyUseCasePage> {
  static const _latCmNum = 11132000.0;
  static const _lonCmNum = 9128800.0;
  static const _geoDen = 10000000.0;
  static const _distanceLimitMeters = 30.0;
  static const _timeLimitSeconds = 5;
  static const _circuitConfigs = <SafetyCircuitConfig>[
    SafetyCircuitConfig(
      profile: SafetyCircuitProfile.base,
      label: 'Base',
      assetPrefix: 'distance30',
      description: '距離と時刻だけを証明する最小構成です。',
    ),
    SafetyCircuitConfig(
      profile: SafetyCircuitProfile.detectionFlag,
      label: 'Detection Flag',
      assetPrefix: 'distance30_detection_flag',
      description: 'UAV 検知フラグとスコア・クラスを追加する軽量案です。',
      requiresVideo: true,
    ),
    SafetyCircuitConfig(
      profile: SafetyCircuitProfile.detectionCommitment,
      label: 'Commitment',
      assetPrefix: 'distance30_detection_commitment',
      description: '座標を Poseidon ハッシュでコミットメント化し、プライバシーを保ちながら接近と検知を証明します。',
      requiresVideo: false,
    ),
    SafetyCircuitConfig(
      profile: SafetyCircuitProfile.featureClassifier,
      label: 'Feature Classifier',
      assetPrefix: 'distance30_feature_classifier',
      description: '外部抽出した特徴量を小さな分類器で評価する拡張案です。',
      requiresVideo: true,
    ),
    SafetyCircuitConfig(
      profile: SafetyCircuitProfile.timeSeries,
      label: 'Time Series (20点)',
      assetPrefix: 'distance30_time_series',
      description: '録画中に収集した最大 20 ペアの時系列データを使い、いずれか 1 点でも接近していれば接近を証明します。',
      requiresVideo: false,
    ),
  ];
  int _selectedTabIndex = 0;
  DroneInputMode _droneInputMode = DroneInputMode.manual;
  SafetyCircuitProfile _selectedCircuitProfile = SafetyCircuitProfile.base;

  final _droneLatController = TextEditingController();
  final _droneLonController = TextEditingController();
  final _droneAltController = TextEditingController();
  final _droneTimeController = TextEditingController();
  final _targetLatController = TextEditingController();
  final _targetLonController = TextEditingController();
  final _targetAltController = TextEditingController();
  final _targetTimeController = TextEditingController();

  final _rapidsnark = Rapidsnark();
  final _witnesscalc = CircomWitnesscalc();

  String _status = 'ドローン側は手入力または Raspberry Pi BLE 受信、利用者側は端末センサー取得で進められます。';
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  void _log(String msg) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _status = msg;
      _logs.add('[$ts] $msg');
      if (_logs.length > 200) _logs.removeAt(0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }
  String _inputJson = '';
  String _publicSignals = '';
  String _proof = '';
  String _verdictTitle = '未実行';
  String _verdictSummary = 'まだ証明は生成されていません。';
  String _privacySummary = '座標そのものは公開せず、真偽だけを共有します。';
  bool _proofValid = false;
  bool _isBusy = false;
  bool _isScanningDrone = false;
  DateTime? _proofStartedAt;
  Duration? _proofElapsed;
  Timer? _proofTimer;
  bool _isAnalyzingVideo = false;
  bool _uavDetectedInVideo = false;
  double? _groundPressureHpa;     // アプリ起動時に記録した地上気圧 (QFE 基準)
  double? _currentPressureHpa;
  double? _currentAltitudeMeters;
  DateTime? _lastSensorReadAt;
  Timer? _autoLocationTimer;
  Timer? _bleRescanTimer;
  // カメラ
  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  Duration _recordingElapsed = Duration.zero;
  Timer? _recordingTimer;
  // データ履歴（最大20件）
  final List<PositionSnapshot> _locationHistory = [];
  final List<UavTelemetryPacket> _droneHistory = [];
  StreamSubscription<Position>? _locationStream;
  StreamSubscription<List<ScanResult>>? _bleScanSubscription;
  int _scanSeq = 0;
  VideoEvidence? _videoEvidence;
  List<String> _videoDetectionLabels = const [];
  List<VideoDetectionDetail> _videoDetectionDetails = const [];
  String _videoDetectionSummary = '動画撮影後に自動解析を行い、UAV 候補が映っているかを判定します。';
  UavYoloDetector? _yoloDetector;
  String _detectionBackendLabel = 'ML Kit fallback';
  String _detectionBackendStatus = 'YOLO モデルがまだ入っていないため、軽量ラベリングで解析します。';
  StreamSubscription<BarometerEvent>? _barometerSubscription;
  UavTelemetryPacket? _lastDroneTelemetry;
  DateTime? _lastDroneSeenAt;

  bool get _hasTargetInputsReady =>
      _targetLatController.text.isNotEmpty &&
      _targetLonController.text.isNotEmpty &&
      _targetAltController.text.isNotEmpty &&
      _targetTimeController.text.isNotEmpty;

  String get _droneModeLabel =>
      _droneInputMode == DroneInputMode.ble ? 'Raspberry Pi BLE 受信' : '手入力';

  SafetyCircuitConfig get _selectedCircuitConfig => _circuitConfigs.firstWhere(
    (config) => config.profile == _selectedCircuitProfile,
  );

  String get _collectionNextAction {
    if (_droneInputMode == DroneInputMode.ble && _lastDroneTelemetry == null) {
      return 'まず Raspberry Pi から受信します';
    }
    if (!_hasTargetInputsReady) {
      return '次に端末情報を取得します';
    }
    if (_videoEvidence == null) {
      return 'そのまま撮影に進めます';
    }
    if (!_uavDetectedInVideo) {
      return '動画解析結果を確認して再撮影または再解析します';
    }
    return '証明実行まで進めます';
  }

  @override
  void initState() {
    super.initState();
    _applyDefaultInputs();
    _startBarometerStream();
    unawaited(_initializeDetectionPipeline());
    // GPS ストリーム開始（1秒ごと）
    _startLocationStream();
    // カメラ初期化 → 自動録画
    unawaited(_initCameraAndRecord());
    // BLE モードなら起動時からスキャン開始、25秒ごとに再スキャン
    _startContinuousBleScan();
  }

  Future<void> _initCameraAndRecord() async {
    // パーミッション取得後にカメラリストが空の場合は再取得
    if (_availableCameras.isEmpty) {
      try {
        _availableCameras = await availableCameras();
      } catch (e) {
        _log('カメラ取得エラー: $e');
        return;
      }
    }
    if (_availableCameras.isEmpty) {
      _log('カメラが見つかりません。カメラ権限を確認してください。');
      return;
    }
    final camera = _availableCameras.first;
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      if (!mounted) { await controller.dispose(); return; }
      setState(() {
        _cameraController = controller;
        _cameraReady = true;
      });
      // 初期化直後に即 startVideoRecording するとバッファ未確保で失敗するため少し待つ
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) await _startRecording();
    } catch (e) {
      _log('カメラ初期化エラー: $e');
    }
  }

  Future<void> _startRecording() async {
    final ctrl = _cameraController;
    if (ctrl == null || !_cameraReady || _isRecording) return;
    try {
      await ctrl.startVideoRecording();
      final now = DateTime.now();
      setState(() {
        _isRecording = true;
        _recordingStartedAt = now;
        _recordingElapsed = Duration.zero;
        _locationHistory.clear();
        _droneHistory.clear();
      });
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (_recordingStartedAt != null && mounted) {
          setState(() {
            _recordingElapsed = DateTime.now().difference(_recordingStartedAt!);
          });
        }
      });
    } catch (e) {
      _log('録画開始エラー: $e');
    }
  }

  Future<void> _stopRecordingAndPrepare() async {
    final ctrl = _cameraController;
    if (ctrl == null || !_isRecording) return;
    _recordingTimer?.cancel();
    try {
      final file = await ctrl.stopVideoRecording();
      final completedAt = DateTime.now();
      final startedAt = _recordingStartedAt ?? completedAt;
      setState(() {
        _isRecording = false;
        _videoEvidence = VideoEvidence(
          path: file.path,
          recordRequestedAt: startedAt,
          recordCompletedAt: completedAt,
          detectionSource: 'camera',
        );
      });
      // 最適ペアを選択してフォームに反映
      _selectBestDataPair();
      // 動画解析
      unawaited(_analyzeVideoEvidence());
    } catch (_) {}
  }

  void _selectBestDataPair() {
    if (_droneHistory.isEmpty || _locationHistory.isEmpty) return;
    // 時刻差が最小のドローン・ユーザーペアを選ぶ
    UavTelemetryPacket? bestDrone;
    PositionSnapshot? bestLocation;
    int minDiff = 999999;
    for (final drone in _droneHistory) {
      for (final loc in _locationHistory) {
        final diff = (drone.unixTimeSec - loc.unixTimeSec).abs();
        if (diff < minDiff) {
          minDiff = diff;
          bestDrone = drone;
          bestLocation = loc;
        }
      }
    }
    if (bestDrone != null) _applyDroneTelemetry(bestDrone);
    if (bestLocation != null && mounted) {
      setState(() {
        _targetLatController.text = bestLocation!.lat.toStringAsFixed(7);
        _targetLonController.text = bestLocation.lon.toStringAsFixed(7);
        _targetAltController.text = bestLocation.alt.toStringAsFixed(1);
        _targetTimeController.text = bestLocation.unixTimeSec.toString();
      });
      _log('録画終了。${_droneHistory.length}件のドローンデータ・${_locationHistory.length}件の位置データから最適ペアを選択しました（時刻差 ${minDiff}s）。');
    }
  }

  void _startLocationStream() {
    _locationStream?.cancel();
    _autoLocationTimer?.cancel();
    _locationStream = Geolocator.getPositionStream(
      locationSettings: Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
              intervalDuration: const Duration(seconds: 1),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
            ),
    ).listen((position) async {
      double alt = _currentAltitudeMeters ?? 0.0;
      final unixSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final snapshot = PositionSnapshot(
        lat: position.latitude,
        lon: position.longitude,
        alt: alt,
        unixTimeSec: unixSec,
      );
      if (!mounted) return;
      setState(() {
        // 録画中なら履歴に追加（最大20件）
        if (_isRecording) {
          _locationHistory.add(snapshot);
          if (_locationHistory.length > 20) _locationHistory.removeAt(0);
        }
        // 現在値を常時更新
        _targetLatController.text = position.latitude.toStringAsFixed(7);
        _targetLonController.text = position.longitude.toStringAsFixed(7);
        _targetAltController.text = alt.toStringAsFixed(1);
        _targetTimeController.text = unixSec.toString();
        _lastSensorReadAt = DateTime.now();
      });
    }, onError: (_) {});
  }

  void _startContinuousBleScan() {
    unawaited(_restartBleScan());
    _bleRescanTimer?.cancel();
    _bleRescanTimer = Timer.periodic(const Duration(seconds: 22), (_) {
      if (!_isScanningDrone && !_isBusy) unawaited(_restartBleScan());
    });
  }

  Future<void> _restartBleScan() async {
    if (_isScanningDrone) return;
    if (mounted) setState(() { _isScanningDrone = true; });
    try {
      // Bluetooth ON 確認
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _log('Bluetooth がオフです。オンにしてください。');
        return;
      }

      await FlutterBluePlus.stopScan();
      await _bleScanSubscription?.cancel();

      _bleScanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          // serviceData から OpenDroneID UUID 0xFFFA を探す
          final odidBytes = UavTelemetryPacket.extractFromServiceData(
            result.advertisementData.serviceData,
          );
          if (odidBytes == null) continue;

          // BasicID → UAS_ID を保持
          final uasId = UavTelemetryPacket.tryParseUasId(odidBytes);
          if (uasId != null && uasId.isNotEmpty) {
            _log('[BLE BasicID] UAS_ID=$uasId rssi=${result.rssi}dBm');
            continue;
          }

          // Location パケット → 即座に反映
          final packet = UavTelemetryPacket.tryParseLocation(odidBytes, _scanSeq++);
          if (packet != null && mounted) {
            _log('[BLE Location] seq=${packet.sequence} '
                'lat=${packet.latitude.toStringAsFixed(6)} '
                'lon=${packet.longitude.toStringAsFixed(6)} '
                'alt=${packet.altitudeMeters.toStringAsFixed(1)}m '
                'airborne=${packet.statusIsAirborne} '
                'rssi=${result.rssi}dBm');
            setState(() => _applyDroneTelemetry(packet));
          }
        }
      });

      // withServices フィルターを使わない:
      // remote_id.py は Service Data (0x16) のみ送信し UUID リスト (0x03) を含まないため
      // Android の withServices フィルターに引っかからずパケットが捨てられてしまう
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));
    } catch (e) {
      _log('BLE スキャンエラー: $e');
    } finally {
      if (mounted) setState(() { _isScanningDrone = false; });
    }
  }

  Future<void> _initializeDetectionPipeline() async {
    try {
      final detector = await UavYoloDetector.tryCreateFromCandidates([
        UavYoloDetector.visdroneFinetunedConfigAsset,
        UavYoloDetector.roboflowDroneConfigAsset,
        UavYoloDetector.defaultConfigAsset,
      ]);
      if (!mounted) {
        detector?.dispose();
        return;
      }

      setState(() {
        _yoloDetector = detector;
        if (detector != null) {
          _detectionBackendLabel = 'YOLO TFLite';
          _detectionBackendStatus =
              detector.description.contains('uav_visdrone_finetuned')
              ? 'VisDrone 事前学習後に UAV へ fine-tune したプロファイルを優先して読み込みました。動画解析とライブ検知の両方でこのモデルを使います。'
              : detector.description.contains('uav_roboflow_drone')
              ? 'Roboflow の UAV 専用プロファイルを優先して読み込みました。動画解析とライブ検知の両方でこのモデルを使います。'
              : 'YOLO モデルを読み込みました。動画フレーム解析では YOLO を優先利用します。';
        } else {
          _detectionBackendLabel = 'ML Kit fallback';
          _detectionBackendStatus =
              'YOLO モデルが無効または未配置のため、軽量ラベリングを利用します。Roboflow 用またはサンプル YOLO 用の config を有効化すると切り替わります。';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _yoloDetector = null;
        _detectionBackendLabel = 'ML Kit fallback';
        _detectionBackendStatus =
            'YOLO 初期化に失敗したため、軽量ラベリングへフォールバックします。error=$error';
      });
    }
  }

  Future<String> _copyAssetToTemp({
    required String assetPath,
    required String fileName,
  }) async {
    final directory = await getTemporaryDirectory();
    final outputFile = File('${directory.path}/$fileName');
    final bytes = (await rootBundle.load(assetPath)).buffer.asUint8List();
    await outputFile.writeAsBytes(bytes, flush: true);
    return outputFile.path;
  }

  void _applyDefaultInputs() {
    _droneLatController.clear();
    _droneLonController.clear();
    _droneAltController.clear();
    _droneTimeController.clear();
    _targetLatController.clear();
    _targetLonController.clear();
    _targetAltController.clear();
    _targetTimeController.clear();

    _droneInputMode = DroneInputMode.manual;
    _selectedCircuitProfile = SafetyCircuitProfile.base;
    _lastDroneTelemetry = null;
    _lastDroneSeenAt = null;
    _log('ドローン側は手入力または Raspberry Pi BLE 受信、利用者側は端末の GPS と気圧センサーで取得できます。');
    _inputJson = '';
    _publicSignals = '';
    _proof = '';
    _verdictTitle = '未実行';
    _verdictSummary = 'まだ証明は生成されていません。';
    _privacySummary = '端末内で証明を生成し、公開するのは安全判定だけです。';
    _proofValid = false;
  }

  int _normalizeLatitude(String value) {
    final latitude = double.parse(value);
    return ((latitude + 90.0) * 10000000).round();
  }

  int _normalizeLongitude(String value) {
    final longitude = double.parse(value);
    return ((longitude + 180.0) * 10000000).round();
  }

  int _metersToCentimeters(String value) {
    return (double.parse(value) * 100).round();
  }

  int _seconds(String value) {
    return int.parse(value);
  }

  bool _hasDroneManualInputs() {
    final lat = _tryParseDouble(_droneLatController.text);
    final lon = _tryParseDouble(_droneLonController.text);
    final alt = _tryParseDouble(_droneAltController.text);
    final time = _tryParseInt(_droneTimeController.text);
    return lat != null &&
        lon != null &&
        alt != null &&
        time != null &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180 &&
        alt.isFinite &&
        time >= 0;
  }

  bool _hasDroneInputsReady() {
    if (_droneInputMode == DroneInputMode.ble) {
      return _lastDroneTelemetry != null;
    }
    return _hasDroneManualInputs();
  }

  double? _tryParseDouble(String value) {
    try {
      return double.parse(value);
    } catch (_) {
      return null;
    }
  }

  int? _tryParseInt(String value) {
    try {
      return int.parse(value);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _buildBaseInputPayload() {
    return <String, String>{
      'drone_lat_e7_norm': _normalizeLatitude(
        _droneLatController.text,
      ).toString(),
      'drone_lon_e7_norm': _normalizeLongitude(
        _droneLonController.text,
      ).toString(),
      'drone_alt_cm': _metersToCentimeters(_droneAltController.text).toString(),
      'drone_time_sec': _seconds(_droneTimeController.text).toString(),
      'target_lat_e7_norm': _normalizeLatitude(
        _targetLatController.text,
      ).toString(),
      'target_lon_e7_norm': _normalizeLongitude(
        _targetLonController.text,
      ).toString(),
      'target_alt_cm': _metersToCentimeters(
        _targetAltController.text,
      ).toString(),
      'target_time_sec': _seconds(_targetTimeController.text).toString(),
    };
  }

  int _estimateDetectionScoreBps() {
    if (!_uavDetectedInVideo) {
      return 0;
    }

    double bestScore = 0.85;
    for (final detail in _videoDetectionDetails) {
      for (final region in detail.regions) {
        if (_looksLikeUavLabel(region.label.toLowerCase())) {
          bestScore = math.max(bestScore, region.confidence);
        }
      }
      for (final label in detail.labels) {
        final parts = label.split(':');
        if (parts.length != 2) {
          continue;
        }
        final rawLabel = parts.first.toLowerCase();
        final confidence = double.tryParse(parts.last) ?? 0.0;
        if (_looksLikeUavLabel(rawLabel)) {
          bestScore = math.max(bestScore, confidence);
        }
      }
    }
    return (bestScore * 10000).round();
  }

  int _deriveStableHash(String input, int seed) {
    var hash = seed;
    for (final byte in utf8.encode(input)) {
      hash = ((hash * 131) + byte) & 0x7fffffff;
    }
    return hash;
  }

  Map<String, dynamic> _buildTimeSeriesInputPayload() {
    const n = 20;

    final droneEntries = _droneHistory.take(n).toList();
    final UavTelemetryPacket? lastDrone =
        droneEntries.isNotEmpty ? droneEntries.last : null;
    while (droneEntries.length < n) {
      droneEntries.add(
        lastDrone ??
            const UavTelemetryPacket(
              latitude: 0,
              longitude: 0,
              altitudeMeters: 0,
              altitudeGeoMeters: 0,
              speedH: 0,
              speedV: 0,
              direction: 0,
              statusIsAirborne: false,
              unixTimeSec: 0,
              sequence: 0,
            ),
      );
    }

    final locationEntries = _locationHistory.take(n).toList();
    final PositionSnapshot? lastLoc =
        locationEntries.isNotEmpty ? locationEntries.last : null;
    while (locationEntries.length < n) {
      locationEntries.add(
        lastLoc ??
            const PositionSnapshot(lat: 0, lon: 0, alt: 0, unixTimeSec: 0),
      );
    }

    String normLat(double lat) => ((lat + 90) * 1e7).round().toString();
    String normLon(double lon) => ((lon + 180) * 1e7).round().toString();
    String altCm(double alt) => (alt * 100).round().toString();

    return {
      'drone_lat_e7_norm':
          droneEntries.map((d) => normLat(d.latitude)).toList(),
      'drone_lon_e7_norm':
          droneEntries.map((d) => normLon(d.longitude)).toList(),
      'drone_alt_cm': droneEntries.map((d) => altCm(d.altitudeMeters)).toList(),
      'drone_time_sec':
          droneEntries.map((d) => d.unixTimeSec.toString()).toList(),
      'target_lat_e7_norm':
          locationEntries.map((l) => normLat(l.lat)).toList(),
      'target_lon_e7_norm':
          locationEntries.map((l) => normLon(l.lon)).toList(),
      'target_alt_cm': locationEntries.map((l) => altCm(l.alt)).toList(),
      'target_time_sec':
          locationEntries.map((l) => l.unixTimeSec.toString()).toList(),
    };
  }

  Map<String, dynamic> _buildInputsPayload() {
    if (_selectedCircuitProfile == SafetyCircuitProfile.timeSeries) {
      return _buildTimeSeriesInputPayload();
    }
    final payload = _buildBaseInputPayload();
    final targetTime = _seconds(_targetTimeController.text);

    switch (_selectedCircuitProfile) {
      case SafetyCircuitProfile.base:
        break;
      case SafetyCircuitProfile.detectionFlag:
        payload.addAll({
          'uav_detected': _uavDetectedInVideo ? '1' : '0',
          'detection_score_bps': _estimateDetectionScoreBps().toString(),
          'detection_class_id': '1',
        });
        break;
      case SafetyCircuitProfile.detectionCommitment:
        final evidence = _videoEvidence;
        // 動画録画開始時刻を frame_time_sec に使う。未撮影の場合は target_time を代入
        final frameTimeSec = evidence != null
            ? (evidence.recordRequestedAt.millisecondsSinceEpoch ~/ 1000)
            : targetTime;
        final commitmentSeed = evidence == null
            ? 'no-evidence'
            : '${evidence.path}|${evidence.recordRequestedAt.toIso8601String()}|${evidence.recordCompletedAt.toIso8601String()}';
        payload.addAll({
          'uav_detected': _uavDetectedInVideo ? '1' : '0',
          'detection_score_bps': _estimateDetectionScoreBps().toString(),
          'detection_class_id': '1',
          'frame_time_sec': frameTimeSec.toString(),
          // 動画フレームの外部ハッシュ（254-bit を hi/lo に分割）
          // 回路内で Poseidon(hi, lo) として frame_binding にバインドされる
          'frame_commitment_hi': _deriveStableHash(commitmentSeed, 17).toString(),
          'frame_commitment_lo': _deriveStableHash(commitmentSeed, 97).toString(),
        });
        break;
      case SafetyCircuitProfile.featureClassifier:
        final detailCount = _videoDetectionDetails.length;
        final regionCount = _videoDetectionDetails.fold<int>(
          0,
          (sum, detail) => sum + detail.regions.length,
        );
        final feature0 = _uavDetectedInVideo ? 60 : 0;
        final feature1 = math.max(detailCount, 1) * 20;
        final feature2 = math.max(regionCount, 1) * 10;
        final feature3 = _detectionBackendLabel.contains('YOLO') ? 30 : 12;
        payload.addAll({
          'frame_time_sec': targetTime.toString(),
          'features': [
            feature0.toString(),
            feature1.toString(),
            feature2.toString(),
            feature3.toString(),
          ],
        });
        break;
      case SafetyCircuitProfile.timeSeries:
        // handled by early return above
        break;
    }

    return payload;
  }

  String _buildInputsJson() {
    return const JsonEncoder.withIndent('  ').convert(_buildInputsPayload());
  }

  double _approxDistanceMeters() {
    final droneLat = _tryParseDouble(_droneLatController.text);
    final droneLon = _tryParseDouble(_droneLonController.text);
    final droneAlt = _tryParseDouble(_droneAltController.text);
    final targetLat = _tryParseDouble(_targetLatController.text);
    final targetLon = _tryParseDouble(_targetLonController.text);
    final targetAlt = _tryParseDouble(_targetAltController.text);

    if (droneLat == null ||
        droneLon == null ||
        droneAlt == null ||
        targetLat == null ||
        targetLon == null ||
        targetAlt == null) {
      return 0;
    }

    final latDiffE7 = ((targetLat - droneLat).abs() * 10000000);
    final lonDiffE7 = ((targetLon - droneLon).abs() * 10000000);
    final altDiffCm = ((targetAlt - droneAlt).abs() * 100);

    final latMeters = (latDiffE7 * _latCmNum / _geoDen) / 100;
    final lonMeters = (lonDiffE7 * _lonCmNum / _geoDen) / 100;
    final altMeters = altDiffCm / 100;

    return math.sqrt(
      latMeters * latMeters + lonMeters * lonMeters + altMeters * altMeters,
    );
  }

  int _approxTimeDelta() {
    final targetTime = _tryParseInt(_targetTimeController.text);
    final droneTime = _tryParseInt(_droneTimeController.text);
    if (targetTime == null || droneTime == null) {
      return 0;
    }
    return (targetTime - droneTime).abs();
  }

  void _applyDroneTelemetry(UavTelemetryPacket packet) {
    _droneLatController.text = packet.latitude.toStringAsFixed(7);
    _droneLonController.text = packet.longitude.toStringAsFixed(7);
    _droneAltController.text = packet.altitudeMeters.toStringAsFixed(1);
    _droneTimeController.text = packet.unixTimeSec.toString();
    _lastDroneTelemetry = packet;
    _lastDroneSeenAt = DateTime.now();
    // 録画中なら履歴に追加（最大20件）
    if (_isRecording) {
      _droneHistory.add(packet);
      if (_droneHistory.length > 20) _droneHistory.removeAt(0);
    }
  }

  void _applySemanticResult(List<dynamic> publicSignals) {
    final within30 =
        publicSignals.isNotEmpty && publicSignals[0].toString() == '1';
    final distanceOk =
        publicSignals.length > 1 && publicSignals[1].toString() == '1';
    final timeOk =
        publicSignals.length > 2 && publicSignals[2].toString() == '1';
    final approxDistance = _approxDistanceMeters();
    final approxTimeDelta = _approxTimeDelta();

    _verdictTitle = within30 ? '接近あり: 要注意' : '安全距離を維持';

    if (within30) {
      _verdictSummary =
          'この証明では、対象者とドローンが30m以内に入り、かつ時刻差も$_timeLimitSeconds秒以内でした。苦情対応や事故検証に使える結果です。';
    } else if (!distanceOk && timeOk) {
      _verdictSummary =
          '時刻は揃っていますが、推定距離は ${approxDistance.toStringAsFixed(1)}m で30mを超えています。住民・観客側にとって安全側の結果です。';
    } else if (distanceOk && !timeOk) {
      _verdictSummary =
          '空間的には近くても、検知時刻との差が ${approxTimeDelta}s あり、同一瞬間の接近とは見なされません。';
    } else {
      _verdictSummary =
          '距離も時刻も閾値外でした。第三者の位置や飛行ルートを公開せず、安全側の判定だけを共有できます。';
    }

    // Commitment 回路（public outputs 10 個）の追加解釈
    // 出力順: [0]within30 [1]distance_ok [2]time_ok [3]detection_ok
    //         [4]frame_time_ok [5]detection_bundle_ok [6]within30_and_detected
    //         [7]drone_commitment [8]target_commitment [9]frame_binding
    if (_selectedCircuitProfile == SafetyCircuitProfile.detectionCommitment &&
        publicSignals.length >= 10) {
      final detectionOk = publicSignals[3].toString() == '1';
      final withinAndDetected = publicSignals[6].toString() == '1';
      final droneCommit = publicSignals[7].toString();
      final targetCommit = publicSignals[8].toString();
      final frameBinding = publicSignals[9].toString();

      if (withinAndDetected) {
        _verdictTitle = '接近あり + UAV 検知: 要注意';
        _verdictSummary =
            '30m 以内の接近と UAV 検知の両方が成立しています。'
            'Poseidon コミットメント付きの証明として記録できます。';
      } else if (within30 && !detectionOk) {
        _verdictSummary +=
            '\n(距離は 30m 以内ですが、UAV 検知スコアが基準を下回っています)';
      }

      final droneShort =
          droneCommit.length > 8 ? '${droneCommit.substring(0, 8)}...' : droneCommit;
      final targetShort =
          targetCommit.length > 8 ? '${targetCommit.substring(0, 8)}...' : targetCommit;
      final frameShort =
          frameBinding.length > 8 ? '${frameBinding.substring(0, 8)}...' : frameBinding;

      _privacySummary =
          'Poseidon ハッシュにより、座標の実値は非公開のまま証明に結びついています。\n'
          'drone:   $droneShort\n'
          'target:  $targetShort\n'
          'frame:   $frameShort\n'
          '(完全な値は Public Signals パネルに表示されます)';
    } else if (_selectedCircuitProfile == SafetyCircuitProfile.timeSeries &&
        publicSignals.length >= 21) {
      // Time Series 回路: outputs = within30[0..19] (indices 0-19) + any_within30 (index 20)
      final anyWithin30 = publicSignals[20].toString() == '1';
      final hitCount = List.generate(20, (i) => publicSignals[i].toString() == '1' ? 1 : 0)
          .fold(0, (a, b) => a + b);
      _verdictTitle = anyWithin30 ? '接近あり: 要注意 (時系列)' : '安全距離を維持 (時系列)';
      _verdictSummary = anyWithin30
          ? '$hitCount / 20 ペアで 30m 以内への接近が確認されました。録画中のデータが証拠として記録されます。'
          : '20 ペアすべてで 30m 以内への接近はありませんでした。録画期間中は安全距離を維持しています。';
      _privacySummary =
          'any_within30=$anyWithin30 のみが公開されます。生の GPS 座標・飛行ルートは外へ出しません。';
      _proofValid = anyWithin30;
    } else {
      _privacySummary =
          '公開信号は within30=$within30, distance_ok=$distanceOk, time_ok=$timeOk のみで、生の位置座標や飛行ルートは外へ出しません。';
    }
  }

  String _assetPathFor(String suffix) {
    final config = _selectedCircuitConfig;
    if (config.profile == SafetyCircuitProfile.base) {
      return 'assets/distance30$suffix';
    }
    return 'assets/circuits/${config.assetPrefix}/${config.assetPrefix}$suffix';
  }

  void _startProofTimer() {
    _proofStartedAt = DateTime.now();
    _proofElapsed = Duration.zero;
    _proofTimer?.cancel();
    _proofTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_proofStartedAt != null) {
        setState(() {
          _proofElapsed = DateTime.now().difference(_proofStartedAt!);
        });
      }
    });
  }

  void _stopProofTimer() {
    _proofTimer?.cancel();
    _proofTimer = null;
    if (_proofStartedAt != null) {
      _proofElapsed = DateTime.now().difference(_proofStartedAt!);
    }
  }

  String get _elapsedLabel {
    final d = _proofElapsed;
    if (d == null) return '';
    final s = d.inMilliseconds / 1000.0;
    return s >= 60
        ? '${d.inMinutes}m ${d.inSeconds % 60}s'
        : '${s.toStringAsFixed(1)}s';
  }

  Future<void> _runProofFlow() async {
    FocusScope.of(context).unfocus();

    _startProofTimer();
    setState(() {
      _isBusy = true;
      _inputJson = '';
      _publicSignals = '';
      _proof = '';
      _proofValid = false;
      _proofElapsed = Duration.zero;
    });
    _log('ドローン入力値と端末取得ログをもとに証明条件を準備しています...');

    try {
      final inputsJson = _buildInputsJson();
      final circuitConfig = _selectedCircuitConfig;
      final graphData = (await rootBundle.load(
        _assetPathFor('.wcd'),
      )).buffer.asUint8List();
      if (graphData.length < 32) {
        throw Exception(
          '${circuitConfig.assetPrefix}.wcd が不足しています。対応する build スクリプトで assets を再生成してください。',
        );
      }

      final verificationKey = await rootBundle.loadString(
        _assetPathFor('_verification_key.json'),
      );

      setState(() { _inputJson = inputsJson; });
      _log('① Witness を計算しています...');

      final zkeyPath = await _copyAssetToTemp(
        assetPath: _assetPathFor('_groth16.zkey'),
        fileName: '${circuitConfig.assetPrefix}_groth16.zkey',
      );

      final witness = await _witnesscalc.calculateWitness(
        inputs: inputsJson,
        graphData: graphData,
      );
      if (witness == null) {
        throw Exception('Witness generation returned null.');
      }

      _log('② Groth16 証明を生成しています...');

      final publicBufferSize = await _rapidsnark.groth16PublicBufferSize(
        zkeyPath: zkeyPath,
      );
      final proveResult = await _rapidsnark.groth16Prove(
        zkeyPath: zkeyPath,
        witness: witness,
        publicBufferSize: publicBufferSize,
      );

      _log('③ 検証キーで確認しています...');

      final proofValid = await _rapidsnark.groth16Verify(
        proof: proveResult.proof,
        inputs: proveResult.publicSignals,
        verificationKey: verificationKey,
      );

      _stopProofTimer();
      final elapsed = _elapsedLabel;

      final decodedPublic =
          jsonDecode(proveResult.publicSignals) as List<dynamic>;

      setState(() {
        _proofValid = proofValid;
        _publicSignals = const JsonEncoder.withIndent('  ').convert(decodedPublic);
        _proof = const JsonEncoder.withIndent('  ').convert(jsonDecode(proveResult.proof));
        _applySemanticResult(decodedPublic);
      });
      _log(proofValid
          ? '✓ 証明・検証 完了（$elapsed）'
          : '✗ 証明は生成できましたが検証に失敗しました（$elapsed）');
    } catch (error) {
      _stopProofTimer();
      final elapsed = _elapsedLabel;
      setState(() {
        _verdictTitle = '実行失敗';
        _verdictSummary = '証明生成フローの途中で停止しました。端末内の witness / zkey / verification key を確認してください。';
        _privacySummary = '失敗時も座標の生データは外部送信していません。';
      });
      _log('✗ エラー（$elapsed）: $error');
    } finally {
      setState(() {
        _isBusy = false;
      });
    }
  }

  /// QFE 方式: 地上気圧 P0 からの相対高度を返す。
  /// P0 未設定時は 0.0 を返す（地上扱い）。
  double _baroToRelativeAlt(double pressureHpa) {
    final p0 = _groundPressureHpa;
    if (p0 == null || p0 <= 0) return 0.0;
    return 44330.0 * (1.0 - math.pow(pressureHpa / p0, 1.0 / 5.255));
  }

  void _startBarometerStream() {
    _barometerSubscription = barometerEventStream().listen(
      (BarometerEvent event) {
        if (!mounted) return;
        // 初回読み取り時に地上気圧を記録（QFE 基準点）
        _groundPressureHpa ??= event.pressure;
        final altitude = _baroToRelativeAlt(event.pressure);
        setState(() {
          _currentPressureHpa = event.pressure;
          _currentAltitudeMeters = altitude;
          _lastSensorReadAt = DateTime.now();
        });
      },
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _currentPressureHpa = null;
          _currentAltitudeMeters = null;
        });
      },
    );
  }

  Future<void> _fillTargetFromDeviceSensors({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _status = '端末のGPSと気圧センサーを読み取っています...';
      });
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('位置情報サービスが無効です。端末の位置情報を有効にしてください。');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('位置情報権限がありません。権限を許可してください。');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      );

      double? altitudeMeters = _currentAltitudeMeters;
      if (altitudeMeters == null) {
        final event = await barometerEventStream().first.timeout(
          const Duration(seconds: 3),
        );
        _groundPressureHpa ??= event.pressure;
        _currentPressureHpa = event.pressure;
        altitudeMeters = _baroToRelativeAlt(event.pressure);
        _currentAltitudeMeters = altitudeMeters;
        _lastSensorReadAt = DateTime.now();
      }

      final altitudeMetersValue = altitudeMeters;
      if (!mounted) return;

      setState(() {
        _targetLatController.text = position.latitude.toStringAsFixed(7);
        _targetLonController.text = position.longitude.toStringAsFixed(7);
        _targetAltController.text = altitudeMetersValue.toStringAsFixed(1);
        _targetTimeController.text =
            (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
      });
      if (!silent) _log('第三者側検知ログを端末実測で更新しました。GPS と気圧センサーを使用しています。');
    } catch (error) {
      if (!mounted) return;
      if (!silent) _log('端末センサー取得エラー: $error');
    }
  }

  Future<void> _captureEvidenceVideo() async {
    _log('カメラを起動して UAV 検知動画を撮影しています...');

    try {
      final picker = ImagePicker();
      final requestedAt = DateTime.now();
      final picked = await picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(seconds: 30),
      );

      if (picked == null) {
        _log('動画撮影がキャンセルされました。');
        return;
      }

      final completedAt = DateTime.now();

      setState(() {
        _videoEvidence = VideoEvidence(
          path: picked.path,
          recordRequestedAt: requestedAt,
          recordCompletedAt: completedAt,
          detectionSource: 'video',
        );
        _uavDetectedInVideo = false;
        _videoDetectionLabels = const [];
        _videoDetectionDetails = const [];
        _targetTimeController.text =
            (requestedAt.millisecondsSinceEpoch ~/ 1000).toString();
        _videoDetectionSummary = '動画を保存しました。これから動画内の UAV 候補を自動解析します。';
      });
      _log('動画を保存しました。動画内の UAV 候補を解析しています...');

      await _analyzeVideoEvidence();
    } catch (error) {
      _log('動画撮影エラー: $error');
    }
  }

  Future<void> _analyzeVideoEvidence() async {
    final evidence = _videoEvidence;
    if (evidence == null) {
      _log('動画がまだありません。先に撮影してください。');
      return;
    }

    setState(() {
      _isAnalyzingVideo = true;
      _videoDetectionSummary = '動画からフレームを切り出して UAV 候補を解析しています...';
    });

    final labels = <String>{};
    final details = <VideoDetectionDetail>[];
    var detected = false;

    try {
      final frames = await _extractVideoFrames(evidence.path);
      if (_yoloDetector != null) {
        final yoloDetections = await _analyzeFramesWithYolo(frames);
        for (final frameResult in yoloDetections) {
          details.add(frameResult);
          for (final label in frameResult.labels) {
            labels.add(label);
            final normalized = label.split(':').first.toLowerCase();
            if (_looksLikeUavLabel(normalized)) {
              detected = true;
            }
          }
        }
      } else {
        final mlKitLabels = await _analyzeFramesWithMlKit(frames);
        for (final frameResult in mlKitLabels) {
          details.add(frameResult);
          for (final label in frameResult.labels) {
            labels.add(label);
            final normalized = label.split(':').first.toLowerCase();
            if (_looksLikeUavLabel(normalized)) {
              detected = true;
            }
          }
          for (final region in frameResult.regions) {
            labels.add(
              '${region.label}:${region.confidence.toStringAsFixed(2)}',
            );
            if (_looksLikeUavLabel(region.label.toLowerCase())) {
              detected = true;
            }
          }
        }
      }

      setState(() {
        _uavDetectedInVideo = detected;
        _videoDetectionLabels = labels.toList()..sort();
        _videoDetectionDetails = details;
        _videoDetectionSummary = detected
            ? '$_detectionBackendLabel により動画内の UAV 候補を検知しました。証明に進めます。'
            : '$_detectionBackendLabel では UAV 候補を確実には検知できませんでした。別角度で再撮影するか、YOLO カスタムモデルを調整すると精度を上げられます。';
      });
      _log(detected
          ? '動画解析で UAV 候補を検知しました。証明を実行できます。'
          : '動画解析では UAV 候補を検知できませんでした。');
    } catch (error) {
      setState(() {
        _uavDetectedInVideo = false;
        _videoDetectionDetails = const [];
        _videoDetectionSummary = '動画解析エラー: $error';
      });
      _log('動画解析エラー: $error');
    } finally {
      setState(() {
        _isAnalyzingVideo = false;
      });
    }
  }

  Future<List<SampledVideoFrame>> _extractVideoFrames(String videoPath) async {
    final tempDir = await getTemporaryDirectory();
    final frames = <SampledVideoFrame>[];
    for (final positionMs in [0, 1000, 2500]) {
      final thumbnailPath = await video_thumbnail.VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: tempDir.path,
        imageFormat: video_thumbnail.ImageFormat.JPEG,
        timeMs: positionMs,
        quality: 85,
      );
      if (thumbnailPath != null) {
        frames.add(SampledVideoFrame(path: thumbnailPath, timeMs: positionMs));
      }
    }
    return frames;
  }

  Future<List<VideoDetectionDetail>> _analyzeFramesWithMlKit(
    List<SampledVideoFrame> frames,
  ) async {
    final details = <VideoDetectionDetail>[];
    final labeler = ImageLabeler(
      options: ImageLabelerOptions(confidenceThreshold: 0.45),
    );
    final objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.single,
        classifyObjects: true,
        multipleObjects: true,
      ),
    );

    try {
      for (final frame in frames) {
        final inputImage = InputImage.fromFilePath(frame.path);
        final imageLabels = await labeler.processImage(inputImage);
        final objects = await objectDetector.processImage(inputImage);
        final regions = await _buildMlKitRegions(
          frame: frame,
          objects: objects,
          labeler: labeler,
        );
        final previewPath = await _buildMlKitPreview(
          frame: frame,
          regions: regions,
        );
        final labels = imageLabels
            .map(
              (label) =>
                  '${label.label}:${label.confidence.toStringAsFixed(2)}',
            )
            .toList();
        details.add(
          VideoDetectionDetail(
            timeMs: frame.timeMs,
            backend: 'ML Kit',
            labels: labels,
            previewPath: previewPath,
            regions: regions,
          ),
        );
      }
    } finally {
      await labeler.close();
      await objectDetector.close();
    }

    return details;
  }

  Future<List<VideoDetectedRegion>> _buildMlKitRegions({
    required SampledVideoFrame frame,
    required List<DetectedObject> objects,
    required ImageLabeler labeler,
  }) async {
    final bytes = await File(frame.path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return const [];
    }

    final tempDir = await getTemporaryDirectory();
    final regions = <VideoDetectedRegion>[];

    for (var index = 0; index < objects.length; index++) {
      final rect = objects[index].boundingBox;
      final left = rect.left.clamp(0, decoded.width - 1).toInt();
      final top = rect.top.clamp(0, decoded.height - 1).toInt();
      final right = rect.right
          .clamp(left + 1, decoded.width.toDouble())
          .toInt();
      final bottom = rect.bottom
          .clamp(top + 1, decoded.height.toDouble())
          .toInt();
      final width = right - left;
      final height = bottom - top;
      if (width < 8 || height < 8) {
        continue;
      }

      final crop = img.copyCrop(
        decoded,
        x: left,
        y: top,
        width: width,
        height: height,
      );
      final cropPath = '${tempDir.path}/mlkit_crop_${frame.timeMs}_$index.jpg';
      await File(cropPath).writeAsBytes(img.encodeJpg(crop, quality: 90));

      final cropLabels = await labeler.processImage(
        InputImage.fromFilePath(cropPath),
      );
      final cropTop = cropLabels.isNotEmpty ? cropLabels.first : null;
      final detectorTop = objects[index].labels.isNotEmpty
          ? objects[index].labels.first
          : null;
      final regionLabel = cropTop?.label ?? detectorTop?.text ?? 'object';
      final regionConfidence =
          cropTop?.confidence ?? detectorTop?.confidence ?? 0.0;

      regions.add(
        VideoDetectedRegion(
          left: left.toDouble(),
          top: top.toDouble(),
          right: right.toDouble(),
          bottom: bottom.toDouble(),
          label: regionLabel,
          confidence: regionConfidence,
        ),
      );
    }

    return regions;
  }

  Future<String?> _buildMlKitPreview({
    required SampledVideoFrame frame,
    required List<VideoDetectedRegion> regions,
  }) async {
    if (regions.isEmpty) {
      return null;
    }

    final bytes = await File(frame.path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }

    for (final region in regions) {
      img.drawRect(
        decoded,
        x1: region.left.toInt(),
        y1: region.top.toInt(),
        x2: region.right.toInt(),
        y2: region.bottom.toInt(),
        color: img.ColorRgb8(17, 142, 104),
        thickness: 4,
      );
    }

    final tempDir = await getTemporaryDirectory();
    final previewPath = '${tempDir.path}/mlkit_preview_${frame.timeMs}.jpg';
    await File(previewPath).writeAsBytes(img.encodeJpg(decoded, quality: 92));
    return previewPath;
  }

  Future<List<VideoDetectionDetail>> _analyzeFramesWithYolo(
    List<SampledVideoFrame> frames,
  ) async {
    final detector = _yoloDetector;
    if (detector == null) {
      return const [];
    }

    final details = <VideoDetectionDetail>[];
    for (final frame in frames) {
      final detections = await detector.detectImageFile(frame.path);
      details.add(
        VideoDetectionDetail(
          timeMs: frame.timeMs,
          backend: 'YOLO TFLite',
          labels: detections
              .map(
                (detection) =>
                    '${detection.label}:${detection.score.toStringAsFixed(2)}',
              )
              .toList(),
          regions: detections
              .map(
                (detection) => VideoDetectedRegion(
                  left: detection.left,
                  top: detection.top,
                  right: detection.right,
                  bottom: detection.bottom,
                  label: detection.label,
                  confidence: detection.score,
                ),
              )
              .toList(),
        ),
      );
    }
    return details;
  }

  bool _looksLikeUavLabel(String label) {
    const keywords = <String>[
      'drone',
      'quadcopter',
      'multirotor',
      'uav',
      'unmanned aerial vehicle',
    ];
    return keywords.any(label.contains);
  }

  Future<void> _fillDroneFromBle() async {
    await _restartBleScan();
  }

  Future<void> _receiveDroneAndCaptureVideo() async {
    if (_droneInputMode == DroneInputMode.ble && _lastDroneTelemetry == null) {
      await _fillDroneFromBle();
      if (!mounted || _lastDroneTelemetry == null) {
        return;
      }
    }

    if (!_hasDroneInputsReady()) {
      setState(() {
        _status =
            'ドローン側ログの Latitude / Longitude / Altitude / Unix Time を入力してください。';
      });
      return;
    }

    await _fillTargetFromDeviceSensors();
    if (!mounted || _status.startsWith('端末センサー取得エラー:')) {
      return;
    }
    await _captureEvidenceVideo();
  }

  Future<void> _runProofFromVideoEvidence() async {
    if (!_hasDroneInputsReady()) {
      _log(_droneInputMode == DroneInputMode.ble
          ? '証明前に Raspberry Pi からドローン側ログを受信してください。'
          : '証明前にドローン側ログを手入力してください。');
      return;
    }
    if (_videoEvidence == null) {
      _log('先に動画を撮影してください。');
      return;
    }
    if (!_uavDetectedInVideo) {
      _log('動画解析で UAV 候補が検出された場合のみ証明できます。');
      return;
    }
    await _runProofFlow();
  }

  BoxDecoration _surfaceDecoration({
    Color color = Colors.white,
    double radius = 22,
    Color borderColor = const Color(0xFFE4E0D3),
  }) {
    return BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor),
      boxShadow: const [
        BoxShadow(
          color: Color(0x140E201D),
          blurRadius: 24,
          offset: Offset(0, 10),
        ),
      ],
    );
  }

  ButtonStyle _primaryActionStyle([Color color = const Color(0xFF0B6E69)]) {
    return FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    );
  }

  Widget _buildNumberField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF8F7F1),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFD9D6C8)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFD9D6C8)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFF0B6E69), width: 1.5),
        ),
      ),
    );
  }

  Widget _buildMetricTile(String label, String value, String helper) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F8F4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE0E7DF)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF4E6762),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Color(0xFF12312E),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              helper,
              style: const TextStyle(fontSize: 11, color: Color(0xFF4E6762)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultPanel({required String title, required String body}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: _surfaceDecoration(radius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF2E3F3C),
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            body.isEmpty ? '$title は証明実行後に表示されます。' : body,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Color(0xFF334643),
            ),
          ),
        ],
      ),
    );
  }

  // ── 新UI: 2タブ設計 ──────────────────────────────────────────

  Widget _buildStatusRow(String label, bool ready, {String value = ''}) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ready ? const Color(0xFF1BAA6A) : const Color(0xFFCCC9BE),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: ready ? const Color(0xFF12312E) : const Color(0xFF8B8B82),
          ),
        ),
        if (value.isNotEmpty) ...[
          const Spacer(),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: Color(0xFF4E6762),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSection({
    required IconData icon,
    required String title,
    required Color accent,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: Color(0xFF1D2C2A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _buildMainTab(double approxDistance, int approxTimeDelta) {
    final droneReady = _hasDroneInputsReady();
    final locationReady = _hasTargetInputsReady;
    final needsVideo = _selectedCircuitConfig.requiresVideo;
    final canProve = droneReady &&
        locationReady &&
        (!needsVideo || (needsVideo && _uavDetectedInVideo));

    final drone = _lastDroneTelemetry;
    final elapsed = _recordingElapsed;
    final elapsedStr = _isRecording
        ? '${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
        : '';

    final String proofLabel;
    if (_isBusy) {
      proofLabel = '処理中... $_elapsedLabel';
    } else if (!droneReady) {
      proofLabel = 'ドローン情報を受信してください';
    } else if (!locationReady) {
      proofLabel = '位置情報を取得しています...';
    } else if (_isRecording) {
      proofLabel = '録画停止後に証明できます';
    } else {
      proofLabel = '▶  証明を実行';
    }
    final VoidCallback? proofAction = (!_isBusy && canProve && !_isRecording)
        ? (needsVideo ? _runProofFromVideoEvidence : _runProofFlow)
        : null;

    // 録画時間バー (最大 20 秒)
    final recProgress = _isRecording
        ? (elapsed.inMilliseconds / 20000.0).clamp(0.0, 1.0)
        : (_videoEvidence != null ? 1.0 : 0.0);

    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Stack(
      children: [
        // ── カメラプレビュー or プレースホルダー（真の全画面）──
        Positioned.fill(
          child: _cameraReady && _cameraController != null
              ? CameraPreview(_cameraController!)
              : const ColoredBox(
                  color: Color(0xFF0A0F0D),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.videocam_off_rounded,
                            color: Color(0xFF4E6762), size: 48),
                        SizedBox(height: 12),
                        Text('カメラを初期化中...',
                            style: TextStyle(color: Color(0xFF4E6762))),
                      ],
                    ),
                  ),
                ),
        ),

        // ── 上部オーバーレイ: アプリ名 + REC インジケーター ──
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(16, topPad + 10, 16, 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.6),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'UAV Safety ZK',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (_isRecording) ...[
                  Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFFF3B30),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'REC  $elapsedStr',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ] else if (_videoEvidence != null) ...[
                  const Icon(Icons.check_circle_rounded,
                      color: Color(0xFF30D158), size: 18),
                  const SizedBox(width: 6),
                  const Text(
                    '録画完了',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── 録画プログレスバー（上端） ──
        if (_isRecording || _videoEvidence != null)
          Positioned(
            top: 0, left: 0, right: 0,
            child: LinearProgressIndicator(
              value: recProgress,
              backgroundColor: Colors.white24,
              color: _isRecording
                  ? const Color(0xFFFF3B30)
                  : const Color(0xFF30D158),
              minHeight: 3,
            ),
          ),

        // ── 下部オーバーレイ: データ + ボタン ──
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.85),
                  Colors.black.withValues(alpha: 0.4),
                  Colors.transparent,
                ],
              ),
            ),
            padding: EdgeInsets.fromLTRB(16, 24, 16, bottomPad + 80),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // データ行
                Row(
                  children: [
                    // ドローン
                    Expanded(
                      child: _buildOverlayDataCard(
                        icon: Icons.airplanemode_active_rounded,
                        label: 'ドローン',
                        ready: droneReady,
                        line1: drone != null
                            ? '${drone.latitude.toStringAsFixed(4)}°'
                            : '未受信',
                        line2: drone != null
                            ? '${drone.longitude.toStringAsFixed(4)}°  ${drone.altitudeMeters.toStringAsFixed(0)}m'
                            : 'BLE 待機中...',
                        count: _droneHistory.length,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 自分
                    Expanded(
                      child: _buildOverlayDataCard(
                        icon: Icons.person_pin_circle_rounded,
                        label: 'あなた',
                        ready: locationReady,
                        line1: locationReady
                            ? '${_targetLatController.text.isEmpty ? '--' : double.tryParse(_targetLatController.text)?.toStringAsFixed(4) ?? '--'}°'
                            : '取得中...',
                        line2: locationReady
                            ? '${double.tryParse(_targetLonController.text)?.toStringAsFixed(4) ?? '--'}°  ${_targetAltController.text}m'
                            : 'GPS 待機中...',
                        count: _locationHistory.length,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 距離・時刻差チップ
                if (droneReady && locationReady)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildMetricChip(
                        '推定距離',
                        '${approxDistance.toStringAsFixed(1)}m',
                        approxDistance <= _distanceLimitMeters
                            ? const Color(0xFF30D158)
                            : const Color(0xFFFF9500),
                      ),
                      const SizedBox(width: 10),
                      _buildMetricChip(
                        '時刻差',
                        '${approxTimeDelta}s',
                        approxTimeDelta <= _timeLimitSeconds
                            ? const Color(0xFF30D158)
                            : const Color(0xFFFF9500),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
                // 録画ボタン + 証明ボタン
                if (_isRecording)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _stopRecordingAndPrepare,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF3B30),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      icon: const Icon(Icons.stop_rounded, size: 22),
                      label: Text(
                        '録画停止 ($elapsedStr)',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                else ...[
                  if (_videoEvidence == null)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _cameraReady ? _startRecording : null,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        icon: const Icon(Icons.fiber_manual_record_rounded,
                            color: Color(0xFFFF3B30)),
                        label: const Text('録画を開始'),
                      ),
                    )
                  else ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _startRecording,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white54),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: const Icon(
                                Icons.fiber_manual_record_rounded,
                                color: Color(0xFFFF3B30),
                                size: 18),
                            label: const Text('撮り直す'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: FilledButton(
                            onPressed: proofAction,
                            style: FilledButton.styleFrom(
                              backgroundColor: canProve && !_isBusy
                                  ? const Color(0xFF30D158)
                                  : Colors.grey.shade700,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: _isBusy
                                ? Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const SizedBox(
                                        width: 16, height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        proofLabel,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  )
                                : Text(
                                    proofLabel,
                                    style: TextStyle(
                                      color: canProve
                                          ? Colors.black87
                                          : Colors.white54,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  // 証明結果
                  if (_verdictTitle != '未実行') ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _proofValid
                            ? const Color(0xFF30D158).withValues(alpha: 0.15)
                            : Colors.red.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _proofValid
                              ? const Color(0xFF30D158)
                              : Colors.red,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _proofValid
                                ? Icons.verified_rounded
                                : Icons.cancel_rounded,
                            color: _proofValid
                                ? const Color(0xFF30D158)
                                : Colors.red,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _verdictTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          if (_proofElapsed != null)
                            Text(
                              _elapsedLabel,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOverlayDataCard({
    required IconData icon,
    required String label,
    required bool ready,
    required String line1,
    required String line2,
    required int count,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: ready
              ? const Color(0xFF30D158).withValues(alpha: 0.6)
              : Colors.white24,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14,
                  color: ready ? const Color(0xFF30D158) : Colors.white54),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: ready ? const Color(0xFF30D158) : Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (count > 0) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count件',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 10),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            line1,
            style: const TextStyle(
              color: Colors.white,
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            line2,
            style: const TextStyle(
              color: Colors.white70,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
          child: Text(
            '詳細',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1D2C2A),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                // 回路セレクター（コンパクト版）
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: _surfaceDecoration(color: const Color(0xFFF8F6EE)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '証明回路',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Color(0xFF1D2C2A),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _circuitConfigs.map((config) {
                          final selected =
                              config.profile == _selectedCircuitProfile;
                          return ChoiceChip(
                            selected: selected,
                            label: Text(config.label),
                            onSelected: _isBusy
                                ? null
                                : (_) => setState(
                                      () => _selectedCircuitProfile =
                                          config.profile,
                                    ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _selectedCircuitConfig.description,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF5C6765),
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ステータスログ
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _isBusy
                        ? Colors.blue.shade50
                        : _proofValid
                        ? Colors.green.shade50
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _isBusy
                          ? Colors.blue.shade200
                          : _proofValid
                          ? Colors.green.shade300
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (_isBusy) ...[
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              _status,
                              style: TextStyle(
                                fontSize: 12,
                                color: _isBusy
                                    ? Colors.blue.shade800
                                    : Colors.black87,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_proofElapsed != null &&
                          _proofElapsed!.inMilliseconds > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          _isBusy
                              ? '経過: $_elapsedLabel'
                              : '処理時間: $_elapsedLabel',
                          style: TextStyle(
                            fontSize: 11,
                            color: _isBusy
                                ? Colors.blue.shade600
                                : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 12),
                _buildResultPanel(title: 'Witness Inputs', body: _inputJson),
                const SizedBox(height: 10),
                _buildResultPanel(
                    title: 'Public Signals', body: _publicSignals),
                const SizedBox(height: 10),
                _buildResultPanel(title: 'Proof JSON', body: _proof),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _proofTimer?.cancel();
    _autoLocationTimer?.cancel();
    _bleRescanTimer?.cancel();
    _recordingTimer?.cancel();
    _locationStream?.cancel();
    _bleScanSubscription?.cancel();
    FlutterBluePlus.stopScan();
    _barometerSubscription?.cancel();
    _yoloDetector?.dispose();
    _cameraController?.dispose();
    _droneLatController.dispose();
    _droneLonController.dispose();
    _droneAltController.dispose();
    _droneTimeController.dispose();
    _targetLatController.dispose();
    _targetLonController.dispose();
    _targetAltController.dispose();
    _targetTimeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final approxDistance = _approxDistanceMeters();
    final approxTimeDelta = _approxTimeDelta();
    final tabs = [
      _buildMainTab(approxDistance, approxTimeDelta),
      _buildDetailsTab(),
    ];

    return Scaffold(
      extendBody: true,
      backgroundColor: Colors.black,
      body: _selectedTabIndex == 0
          ? _buildMainTab(approxDistance, approxTimeDelta)
          : _selectedTabIndex == 1
              ? Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFFE8F3EE), Color(0xFFF3F2EA), Color(0xFFF8F5EC)],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: _buildDetailsTab(),
                    ),
                  ),
                )
              : _buildLogTab(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: 'メイン',
          ),
          NavigationDestination(
            icon: Icon(Icons.data_object_outlined),
            selectedIcon: Icon(Icons.data_object_rounded),
            label: '詳細',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal_rounded),
            label: 'ログ',
          ),
        ],
      ),
    );
  }

  Widget _buildLogTab() {
    return Container(
      color: const Color(0xFF0D1117),
      child: SafeArea(
        child: Column(
          children: [
            // ヘッダー
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.terminal_rounded, color: Color(0xFF58A6FF), size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'コンソールログ',
                    style: TextStyle(
                      color: Color(0xFF58A6FF),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_logs.length} 件',
                    style: const TextStyle(color: Color(0xFF8B949E), fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => setState(() => _logs.clear()),
                    child: const Icon(Icons.delete_outline_rounded,
                        color: Color(0xFF8B949E), size: 18),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF21262D), height: 1),
            // ログリスト
            Expanded(
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        'ログがまだありません',
                        style: TextStyle(color: Color(0xFF484F58), fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      controller: _logScrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: _logs.length,
                      itemBuilder: (context, i) {
                        final line = _logs[i];
                        final isError = line.contains('エラー') || line.contains('✗');
                        final isSuccess = line.contains('✓') || line.contains('完了');
                        final isBle = line.contains('[BLE');
                        Color textColor = const Color(0xFFC9D1D9);
                        if (isError) textColor = const Color(0xFFF85149);
                        if (isSuccess) textColor = const Color(0xFF3FB950);
                        if (isBle) textColor = const Color(0xFF79C0FF);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            line,
                            style: TextStyle(
                              color: textColor,
                              fontSize: 11,
                              fontFamily: 'monospace',
                              height: 1.5,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
