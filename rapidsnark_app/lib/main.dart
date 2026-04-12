import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:circom_witnesscalc/circom_witnesscalc.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_rapidsnark/flutter_rapidsnark.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import 'uav_live_detection_page.dart';
import 'uav_yolo_detector.dart';

void main() {
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

class UavTelemetryPacket {
  const UavTelemetryPacket({
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.unixTimeSec,
    required this.sequence,
    required this.rssi,
  });

  static const manufacturerId = 0x02E5;
  static const magic = 0x5A;
  static const version = 0x01;

  final double latitude;
  final double longitude;
  final double altitudeMeters;
  final int unixTimeSec;
  final int sequence;
  final int rssi;

  static UavTelemetryPacket? fromManufacturerData({
    required List<int> bytes,
    required int rssi,
  }) {
    if (bytes.length < 17 || bytes[0] != magic || bytes[1] != version) {
      return null;
    }

    final raw = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(raw);
    final latE7 = data.getInt32(2, Endian.little);
    final lonE7 = data.getInt32(6, Endian.little);
    final altitudeDecimeters = data.getInt16(10, Endian.little);
    final unixTimeSec = data.getUint32(12, Endian.little);
    final sequence = data.getUint8(16);

    return UavTelemetryPacket(
      latitude: latE7 / 10000000.0,
      longitude: lonE7 / 10000000.0,
      altitudeMeters: altitudeDecimeters / 10.0,
      unixTimeSec: unixTimeSec,
      sequence: sequence,
      rssi: rssi,
    );
  }
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
  const SampledVideoFrame({
    required this.path,
    required this.timeMs,
  });

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
  int _selectedTabIndex = 0;

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

  String _status = 'BLE・動画・証明の流れで安全距離確認を実行できます。';
  String _inputJson = '';
  String _publicSignals = '';
  String _proof = '';
  String _verdictTitle = '未実行';
  String _verdictSummary = 'まだ証明は生成されていません。';
  String _privacySummary = '座標そのものは公開せず、真偽だけを共有します。';
  bool _proofValid = false;
  bool _isBusy = false;
  bool _isScanningDrone = false;
  bool _isAnalyzingVideo = false;
  bool _uavDetectedInVideo = false;
  double? _currentPressureHpa;
  double? _currentAltitudeMeters;
  DateTime? _lastSensorReadAt;
  UavTelemetryPacket? _lastDroneTelemetry;
  DateTime? _lastDroneSeenAt;
  VideoEvidence? _videoEvidence;
  List<String> _videoDetectionLabels = const [];
  List<VideoDetectionDetail> _videoDetectionDetails = const [];
  String _videoDetectionSummary =
      '動画撮影後に自動解析を行い、UAV 候補が映っているかを判定します。';
  UavYoloDetector? _yoloDetector;
  String _detectionBackendLabel = 'ML Kit fallback';
  String _detectionBackendStatus =
      'YOLO モデルがまだ入っていないため、軽量ラベリングで解析します。';
  StreamSubscription<BarometerEvent>? _barometerSubscription;

  @override
  void initState() {
    super.initState();
    _applyDefaultInputs();
    _startBarometerStream();
    unawaited(_initializeDetectionPipeline());
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
          _detectionBackendStatus = detector.description.contains(
                'uav_visdrone_finetuned',
              )
              ? 'VisDrone 事前学習後に UAV へ fine-tune したプロファイルを優先して読み込みました。動画解析とライブ検知の両方でこのモデルを使います。'
              : detector.description.contains(
                  'uav_roboflow_drone',
                )
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
    _droneLatController.text = '35.6891390';
    _droneLonController.text = '139.6917000';
    _droneAltController.text = '12.0';
    _droneTimeController.text = '1711447200';
    _targetLatController.text = '35.6891590';
    _targetLonController.text = '139.6917180';
    _targetAltController.text = '10.0';
    _targetTimeController.text = '1711447203';

    _status = 'BLE・動画・証明の流れで安全距離確認を実行できます。';
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

  String _buildInputsJson() {
    final payload = <String, String>{
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
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  double _approxDistanceMeters() {
    final droneLat = double.parse(_droneLatController.text);
    final droneLon = double.parse(_droneLonController.text);
    final droneAlt = double.parse(_droneAltController.text);
    final targetLat = double.parse(_targetLatController.text);
    final targetLon = double.parse(_targetLonController.text);
    final targetAlt = double.parse(_targetAltController.text);

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
    return (_seconds(_targetTimeController.text) -
            _seconds(_droneTimeController.text))
        .abs();
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
      _verdictSummary = '距離も時刻も閾値外でした。第三者の位置や飛行ルートを公開せず、安全側の判定だけを共有できます。';
    }

    _privacySummary =
        '公開信号は within30=$within30, distance_ok=$distanceOk, time_ok=$timeOk のみで、生の位置座標や飛行ルートは外へ出しません。';
  }

  Future<void> _runProofFlow() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _isBusy = true;
      _status = 'BLE検知ログと飛行ログの突合条件を端末内で準備しています...';
      _inputJson = '';
      _publicSignals = '';
      _proof = '';
      _proofValid = false;
    });

    try {
      final inputsJson = _buildInputsJson();
      final graphData = (await rootBundle.load(
        'assets/distance30.wcd',
      )).buffer.asUint8List();
      if (graphData.length < 32) {
        throw Exception(
          'distance30.wcd が不足しています。build-circuit を入れて assets を再生成してください。',
        );
      }

      final verificationKey = await rootBundle.loadString(
        'assets/distance30_verification_key.json',
      );

      setState(() {
        _inputJson = inputsJson;
        _status = '端末内で witness を計算しています...';
      });

      final zkeyPath = await _copyAssetToTemp(
        assetPath: 'assets/distance30_groth16.zkey',
        fileName: 'distance30_groth16.zkey',
      );

      final witness = await _witnesscalc.calculateWitness(
        inputs: inputsJson,
        graphData: graphData,
      );
      if (witness == null) {
        throw Exception('Witness generation returned null.');
      }

      setState(() {
        _status = 'Groth16 証明を生成しています...';
      });

      final publicBufferSize = await _rapidsnark.groth16PublicBufferSize(
        zkeyPath: zkeyPath,
      );
      final proveResult = await _rapidsnark.groth16Prove(
        zkeyPath: zkeyPath,
        witness: witness,
        publicBufferSize: publicBufferSize,
      );

      setState(() {
        _status = '検証キーで真偽を確認しています...';
      });

      final proofValid = await _rapidsnark.groth16Verify(
        proof: proveResult.proof,
        inputs: proveResult.publicSignals,
        verificationKey: verificationKey,
      );

      final decodedPublic =
          jsonDecode(proveResult.publicSignals) as List<dynamic>;

      setState(() {
        _proofValid = proofValid;
        _status = proofValid
            ? '住民端末上でゼロ知識証明の生成と検証が完了しました。'
            : '証明は作れましたが、検証は失敗しました。';
        _publicSignals = const JsonEncoder.withIndent(
          '  ',
        ).convert(decodedPublic);
        _proof = const JsonEncoder.withIndent(
          '  ',
        ).convert(jsonDecode(proveResult.proof));
        _applySemanticResult(decodedPublic);
      });
    } catch (error) {
      setState(() {
        _status = 'Error: $error';
        _verdictTitle = '実行失敗';
        _verdictSummary =
            '証明生成フローの途中で停止しました。端末内の witness / zkey / verification key を確認してください。';
        _privacySummary = '失敗時も座標の生データは外部送信していません。';
      });
    } finally {
      setState(() {
        _isBusy = false;
      });
    }
  }

  void _startBarometerStream() {
    _barometerSubscription = barometerEventStream().listen(
      (BarometerEvent event) {
        if (!mounted) return;
        final altitude =
            44330.0 * (1.0 - math.pow(event.pressure / 1013.25, 1 / 5.255));
        setState(() {
          _currentPressureHpa = event.pressure;
          _currentAltitudeMeters = altitude.toDouble();
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

  Future<void> _fillTargetFromDeviceSensors() async {
    setState(() {
      _status = '端末のGPSと気圧センサーを読み取っています...';
    });

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
        altitudeMeters =
            44330.0 *
            (1.0 - math.pow(event.pressure / 1013.25, 1 / 5.255)).toDouble();
        _currentPressureHpa = event.pressure;
        _currentAltitudeMeters = altitudeMeters;
        _lastSensorReadAt = DateTime.now();
      }

      final altitudeMetersValue = altitudeMeters;

      setState(() {
        _targetLatController.text = position.latitude.toStringAsFixed(7);
        _targetLonController.text = position.longitude.toStringAsFixed(7);
        _targetAltController.text = altitudeMetersValue.toStringAsFixed(1);
        _targetTimeController.text =
            (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
        _status = '第三者側検知ログを端末実測で更新しました。GPS と気圧センサーを使用しています。';
      });
    } catch (error) {
      setState(() {
        _status = '端末センサー取得エラー: $error';
      });
    }
  }

  Future<void> _captureEvidenceVideo() async {
    setState(() {
      _status = 'カメラを起動して UAV 検知動画を撮影しています...';
    });

    try {
      final picker = ImagePicker();
      final requestedAt = DateTime.now();
      final picked = await picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(seconds: 30),
      );

      if (picked == null) {
        setState(() {
          _status = '動画撮影がキャンセルされました。';
        });
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
        _status = '動画を保存しました。動画内の UAV 候補を解析しています...';
      });

      await _analyzeVideoEvidence();
    } catch (error) {
      setState(() {
        _status = '動画撮影エラー: $error';
      });
    }
  }

  Future<void> _analyzeVideoEvidence() async {
    final evidence = _videoEvidence;
    if (evidence == null) {
      setState(() {
        _status = '動画がまだありません。先に撮影してください。';
      });
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
            labels.add('${region.label}:${region.confidence.toStringAsFixed(2)}');
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
        _status = detected
            ? '動画解析で UAV 候補を検知しました。証明を実行できます。'
            : '動画解析では UAV 候補を検知できませんでした。';
      });
    } catch (error) {
      setState(() {
        _uavDetectedInVideo = false;
        _videoDetectionDetails = const [];
        _videoDetectionSummary = '動画解析エラー: $error';
        _status = '動画解析エラー: $error';
      });
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
      final thumbnailPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: tempDir.path,
        imageFormat: ImageFormat.JPEG,
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
            .map((label) => '${label.label}:${label.confidence.toStringAsFixed(2)}')
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
      final right = rect.right.clamp(left + 1, decoded.width.toDouble()).toInt();
      final bottom = rect.bottom.clamp(top + 1, decoded.height.toDouble()).toInt();
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
      final cropPath =
          '${tempDir.path}/mlkit_crop_${frame.timeMs}_$index.jpg';
      await File(cropPath).writeAsBytes(img.encodeJpg(crop, quality: 90));

      final cropLabels = await labeler.processImage(InputImage.fromFilePath(cropPath));
      final cropTop = cropLabels.isNotEmpty ? cropLabels.first : null;
      final detectorTop = objects[index].labels.isNotEmpty ? objects[index].labels.first : null;
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
              .map((detection) => '${detection.label}:${detection.score.toStringAsFixed(2)}')
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
    if (_isScanningDrone) {
      return;
    }

    setState(() {
      _isScanningDrone = true;
      _status = 'UAV の BLE 広告を探索しています...';
    });

    StreamSubscription<List<ScanResult>>? scanSubscription;

    try {
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception('Bluetooth が OFF です。端末の Bluetooth を ON にしてください。');
      }

      final completer = Completer<UavTelemetryPacket>();
      scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final manufacturerData =
              result.advertisementData.manufacturerData[UavTelemetryPacket.manufacturerId];
          if (manufacturerData == null) {
            continue;
          }

          final packet = UavTelemetryPacket.fromManufacturerData(
            bytes: manufacturerData,
            rssi: result.rssi,
          );

          if (packet != null && !completer.isCompleted) {
            completer.complete(packet);
          }
        }
      });

      await FlutterBluePlus.stopScan();
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));

      final packet = await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw Exception(
          'UAV の広告を検出できませんでした。ラズパイ側で remote_id.py を起動し、近くに置いて再試行してください。',
        ),
      );

      await FlutterBluePlus.stopScan();

      setState(() {
        _lastDroneTelemetry = packet;
        _lastDroneSeenAt = DateTime.now();
        _droneLatController.text = packet.latitude.toStringAsFixed(7);
        _droneLonController.text = packet.longitude.toStringAsFixed(7);
        _droneAltController.text = packet.altitudeMeters.toStringAsFixed(1);
        _droneTimeController.text = packet.unixTimeSec.toString();
        _status =
            'UAV の BLE 広告を受信しました。ドローン側ログを自動更新しています。';
      });
    } catch (error) {
      setState(() {
        _status = 'UAV 受信エラー: $error';
      });
    } finally {
      await FlutterBluePlus.stopScan();
      await scanSubscription?.cancel();
      if (mounted) {
        setState(() {
          _isScanningDrone = false;
        });
      }
    }
  }

  Future<void> _receiveDroneAndCaptureVideo() async {
    await _fillDroneFromBle();
    if (!mounted || _status.startsWith('UAV 受信エラー:')) {
      return;
    }
    await _fillTargetFromDeviceSensors();
    if (!mounted || _status.startsWith('端末センサー取得エラー:')) {
      return;
    }
    await _captureEvidenceVideo();
  }

  Future<void> _runProofFromVideoEvidence() async {
    if (_lastDroneTelemetry == null) {
      setState(() {
        _status = '先に UAV の BLE 広告を受信してください。';
      });
      return;
    }
    if (_videoEvidence == null) {
      setState(() {
        _status = '先に動画を撮影してください。';
      });
      return;
    }
    if (!_uavDetectedInVideo) {
      setState(() {
        _status = '動画解析で UAV 候補が検出された場合のみ証明できます。';
      });
      return;
    }
    await _runProofFlow();
  }

  Future<void> _openLiveDetectionPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UavLiveDetectionPage(
          detector: _yoloDetector,
          detectorLabel: _detectionBackendLabel,
        ),
      ),
    );
  }

  Widget _buildInfoCard({
    required String eyebrow,
    required String title,
    required String body,
    Color? color,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(
        color: color ?? Colors.white,
        radius: 28,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: const TextStyle(
              color: Color(0xFF56716E),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF1D2C2A),
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(
              color: Color(0xFF3B4D4A),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
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

  Widget _buildCardTitle({
    required IconData icon,
    required String title,
    required String subtitle,
    Color accent = const Color(0xFF0B6E69),
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: Color(0xFF1D2C2A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF5C6765),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  ButtonStyle _primaryActionStyle([Color color = const Color(0xFF0B6E69)]) {
    return FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
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

  Widget _buildCoordinateCard({
    required String title,
    required String subtitle,
    required TextEditingController latController,
    required TextEditingController lonController,
    required TextEditingController altController,
    required TextEditingController timeController,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCardTitle(
            icon: Icons.edit_location_alt_outlined,
            title: title,
            subtitle: subtitle,
          ),
          const SizedBox(height: 16),
          _buildNumberField('Latitude', latController),
          const SizedBox(height: 10),
          _buildNumberField('Longitude', lonController),
          const SizedBox(height: 10),
          _buildNumberField('Altitude (m)', altController),
          const SizedBox(height: 10),
          _buildNumberField('Unix Time (sec)', timeController),
        ],
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
                fontSize: 12,
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
              style: const TextStyle(fontSize: 12, color: Color(0xFF4E6762)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSensorCard() {
    final pressureText = _currentPressureHpa == null
        ? '未取得'
        : '${_currentPressureHpa!.toStringAsFixed(2)} hPa';
    final altitudeText = _currentAltitudeMeters == null
        ? '未取得'
        : '${_currentAltitudeMeters!.toStringAsFixed(1)} m';
    final updatedText = _lastSensorReadAt == null
        ? 'まだセンサー読込前です'
        : '最終更新: ${_lastSensorReadAt!.hour.toString().padLeft(2, '0')}:${_lastSensorReadAt!.minute.toString().padLeft(2, '0')}:${_lastSensorReadAt!.second.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCardTitle(
            icon: Icons.sensors_outlined,
            title: '端末センサー',
            subtitle: 'GPS と気圧センサーで第三者側ログを埋めます。',
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _buildMetricTile('気圧', pressureText, 'barometer'),
              const SizedBox(width: 10),
              _buildMetricTile('推定高度', altitudeText, 'device altitude'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            updatedText,
            style: const TextStyle(color: Color(0xFF5C6765), fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isBusy ? null : _fillTargetFromDeviceSensors,
            style: _primaryActionStyle(),
            icon: const Icon(Icons.my_location_rounded),
            label: const Text('この端末の値を使う'),
          ),
        ],
      ),
    );
  }

  Widget _buildDroneBleCard() {
    final packet = _lastDroneTelemetry;
    final seenText = _lastDroneSeenAt == null
        ? 'まだ UAV の広告を受信していません'
        : '最終受信: ${_lastDroneSeenAt!.hour.toString().padLeft(2, '0')}:${_lastDroneSeenAt!.minute.toString().padLeft(2, '0')}:${_lastDroneSeenAt!.second.toString().padLeft(2, '0')}';
    final packetSummary = packet == null
        ? 'manufacturer=0x${UavTelemetryPacket.manufacturerId.toRadixString(16).padLeft(4, '0')} を待機中'
        : 'lat=${packet.latitude.toStringAsFixed(7)}, lon=${packet.longitude.toStringAsFixed(7)}, alt=${packet.altitudeMeters.toStringAsFixed(1)}m, t=${packet.unixTimeSec}, seq=${packet.sequence}, RSSI=${packet.rssi}dBm';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCardTitle(
            icon: Icons.bluetooth_searching_rounded,
            title: 'UAV BLE受信',
            subtitle: 'UAV の広告から位置・高度・時刻を受信します。',
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F5EE),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              packetSummary,
              style: const TextStyle(
                color: Color(0xFF334643),
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            seenText,
            style: const TextStyle(color: Color(0xFF5C6765), fontSize: 12),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isBusy || _isScanningDrone ? null : _fillDroneFromBle,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Text(
                    _isScanningDrone ? '探索中...' : 'BLEを受信',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _isBusy || _isScanningDrone
                      ? null
                      : _receiveDroneAndCaptureVideo,
                  style: _primaryActionStyle(const Color(0xFF27514F)),
                  child: const Text('受信して撮影'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F0E8),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              '動画解析とライブ検知の2モードを使えます。',
              style: TextStyle(
                color: Color(0xFF4E6762),
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _isBusy ? null : _openLiveDetectionPage,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text('ライブ検知を開く'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoEvidenceCard() {
    final evidence = _videoEvidence;
    final summary = evidence == null
        ? 'まだ動画は撮影されていません。BLE で UAV を受信したあと、アプリのカメラで記録します。'
        : 'path=${evidence.path}\nstart=${evidence.recordRequestedAt.toIso8601String()}\nend=${evidence.recordCompletedAt.toIso8601String()}';
    final labelsText = _videoDetectionLabels.isEmpty
        ? 'まだラベルはありません'
        : _videoDetectionLabels.join(', ');
    final detailWidgets = _videoDetectionDetails.isEmpty
        ? [
            const Text(
              'フレーム別の検知結果はまだありません。動画を解析すると、各時点で何を検知したかをここに表示します。',
              style: TextStyle(
                color: Color(0xFF5C6765),
                height: 1.4,
              ),
            ),
          ]
        : _videoDetectionDetails.map((detail) {
            final labels = detail.labels.isEmpty
                ? '検知なし'
                : detail.labels.join(', ');
            final regionSummary = detail.regions.isEmpty
                ? '位置情報なし'
                : detail.regions
                    .map(
                      (region) =>
                          '${region.label}:${region.confidence.toStringAsFixed(2)} '
                          '(${region.left.toStringAsFixed(0)},${region.top.toStringAsFixed(0)})-'
                          '(${region.right.toStringAsFixed(0)},${region.bottom.toStringAsFixed(0)})',
                    )
                    .join('\n');
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (detail.previewPath != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(detail.previewPath!),
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  SelectableText(
                    '[${detail.backend}] t=${(detail.timeMs / 1000).toStringAsFixed(1)}s\n'
                    'labels: $labels\n'
                    'boxes:\n$regionSummary',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Color(0xFF334643),
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            );
          }).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCardTitle(
            icon: Icons.videocam_outlined,
            title: '動画検知',
            subtitle: '動画を数フレーム解析して、検知結果を確認します。',
            accent: const Color(0xFF7A4B00),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F7F4),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '検知バックエンド: $_detectionBackendLabel',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF12312E),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _detectionBackendStatus,
                  style: const TextStyle(
                    color: Color(0xFF4E6762),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            summary,
            style: const TextStyle(
              color: Color(0xFF334643),
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFBF7EC),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _uavDetectedInVideo ? '自動検知: UAV候補あり' : '自動検知: 未検出',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF5A3A00),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _videoDetectionSummary,
                  style: const TextStyle(
                    color: Color(0xFF5C6765),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  'labels=$labelsText',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Color(0xFF334643),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'フレーム別の検知内容',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF5A3A00),
                  ),
                ),
                ...detailWidgets,
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _isBusy || _isAnalyzingVideo ? null : _captureEvidenceVideo,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: const Text('動画を再撮影'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: evidence == null || _isBusy || _isAnalyzingVideo
                      ? null
                      : _analyzeVideoEvidence,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  child: Text(_isAnalyzingVideo ? '解析中...' : '動画を再解析'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _isBusy || _isAnalyzingVideo
                      ? null
                      : _runProofFromVideoEvidence,
                  style: _primaryActionStyle(const Color(0xFF7A4B00)),
                  child: const Text('動画検知で証明実行'),
                ),
              ),
            ],
          ),
        ],
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

  int _currentProcessStep() {
    if (_proofValid || _proof.isNotEmpty || _publicSignals.isNotEmpty) {
      return 4;
    }
    if (_uavDetectedInVideo || _videoEvidence != null || _isAnalyzingVideo) {
      return 3;
    }
    if (_lastDroneTelemetry != null ||
        _targetLatController.text.isNotEmpty ||
        _targetLonController.text.isNotEmpty) {
      return 2;
    }
    return 1;
  }

  Widget _buildProcessFlowCard() {
    final currentStep = _currentProcessStep();
    const steps = <(String, String)>[
      ('1', 'BLEと端末情報を集める'),
      ('2', '動画を撮影して検知する'),
      ('3', '証明して結果を見る'),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '進め方',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: Color(0xFF1D2C2A),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '左から順に進めると、証明までたどれます。',
            style: TextStyle(color: Color(0xFF5C6765), height: 1.45),
          ),
          const SizedBox(height: 12),
          ...steps.map((step) {
            final number = step.$1;
            final label = step.$2;
            final stepIndex = int.parse(number);
            final isDone = currentStep > stepIndex;
            final isCurrent = currentStep == stepIndex;
            final accent = isDone || isCurrent
                ? const Color(0xFF0B6E69)
                : const Color(0xFFD5D2C4);
            final fill = isDone
                ? const Color(0xFFE2F2EC)
                : isCurrent
                ? const Color(0xFFEAF4F1)
                : const Color(0xFFF6F4EC);
            final suffix = isDone
                ? '完了'
                : isCurrent
                ? 'いまここ'
                : '次';
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent),
              ),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      number,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Color(0xFF1D2C2A),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    suffix,
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTabSection(List<Widget> children) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 14, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildQuickActionsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _surfaceDecoration(color: const Color(0xFFF8F6EE)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'よく使う操作',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: Color(0xFF1D2C2A),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => setState(() => _selectedTabIndex = 1),
                  style: _primaryActionStyle(),
                  icon: const Icon(Icons.sensors_outlined),
                  label: const Text('情報を集める'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => setState(() => _selectedTabIndex = 2),
                  style: _primaryActionStyle(const Color(0xFF7A4B00)),
                  icon: const Icon(Icons.video_camera_back_outlined),
                  label: const Text('動画を検知'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _selectedTabIndex = 3),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('証明タブへ進む'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewTab(double approxDistance, int approxTimeDelta) {
    return _buildTabSection([
      _buildInfoCard(
        eyebrow: '概要',
        title: 'UAV Safety Proof Demo',
        body: 'BLE 受信、動画検知、ゼロ知識証明を 1 つの流れで実行します。',
        color: const Color(0xFFDCEFE7),
      ),
      const SizedBox(height: 14),
      _buildProcessFlowCard(),
      const SizedBox(height: 14),
      _buildQuickActionsCard(),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: _surfaceDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '現在の状態',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: Color(0xFF1D2C2A),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _status,
              style: const TextStyle(
                color: Color(0xFF3B4D4A),
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildMetricTile(
                  '推定距離',
                  '${approxDistance.toStringAsFixed(1)}m',
                  '閾値 ${_distanceLimitMeters.toStringAsFixed(0)}m',
                ),
                const SizedBox(width: 10),
                _buildMetricTile(
                  '時刻差',
                  '${approxTimeDelta}s',
                  '閾値 $_timeLimitSeconds s',
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _buildInfoCard(
        eyebrow: _proofValid ? '判定' : '結果',
        title: _verdictTitle,
        body: '$_verdictSummary\n$_privacySummary',
        color: _proofValid
            ? const Color(0xFFE7F2ED)
            : const Color(0xFFF4EFE2),
      ),
    ]);
  }

  Widget _buildCollectionTab() {
    return _buildTabSection([
      _buildSensorCard(),
      const SizedBox(height: 14),
      _buildDroneBleCard(),
      const SizedBox(height: 14),
      _buildCoordinateCard(
        title: 'ドローン側ログ',
        subtitle: 'BLE または運航ログから入る値です。',
        latController: _droneLatController,
        lonController: _droneLonController,
        altController: _droneAltController,
        timeController: _droneTimeController,
      ),
      const SizedBox(height: 14),
      _buildCoordinateCard(
        title: '第三者側ログ',
        subtitle: 'スマホで観測した位置・高度・時刻です。',
        latController: _targetLatController,
        lonController: _targetLonController,
        altController: _targetAltController,
        timeController: _targetTimeController,
      ),
    ]);
  }

  Widget _buildDetectionTab() {
    return _buildTabSection([
      _buildVideoEvidenceCard(),
    ]);
  }

  Widget _buildProofTab() {
    return _buildTabSection([
      FilledButton(
        onPressed: _isBusy ? null : _runProofFromVideoEvidence,
        style: _primaryActionStyle(),
        child: _isBusy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : const Text('Generate And Verify Proof'),
      ),
      const SizedBox(height: 14),
      _buildResultPanel(title: 'Witness Inputs', body: _inputJson),
      const SizedBox(height: 12),
      _buildResultPanel(title: 'Public Signals', body: _publicSignals),
      const SizedBox(height: 12),
      _buildResultPanel(title: 'Proof JSON', body: _proof),
    ]);
  }

  @override
  void dispose() {
    _barometerSubscription?.cancel();
    _yoloDetector?.dispose();
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
      _buildOverviewTab(approxDistance, approxTimeDelta),
      _buildCollectionTab(),
      _buildDetectionTab(),
      _buildProofTab(),
    ];

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFE8F3EE),
              Color(0xFFF3F2EA),
              Color(0xFFF8F5EC),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildInfoCard(
                  eyebrow: 'UAV SAFETY ZK',
                  title: 'UAV Safety Proof Demo',
                  body: 'BLE と動画を使って、安全距離の証明を端末内で行います。',
                  color: const Color(0xFFDCEFE7),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: IndexedStack(
                    index: _selectedTabIndex,
                    children: tabs,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: '概要',
          ),
          NavigationDestination(
            icon: Icon(Icons.sensors_outlined),
            selectedIcon: Icon(Icons.sensors_rounded),
            label: '収集',
          ),
          NavigationDestination(
            icon: Icon(Icons.visibility_outlined),
            selectedIcon: Icon(Icons.visibility_rounded),
            label: '検知',
          ),
          NavigationDestination(
            icon: Icon(Icons.verified_outlined),
            selectedIcon: Icon(Icons.verified_rounded),
            label: '証明',
          ),
        ],
      ),
    );
  }
}
