import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class UavYoloConfig {
  const UavYoloConfig({
    required this.enabled,
    required this.modelAsset,
    required this.labelsAsset,
    required this.scoreThreshold,
    required this.iouThreshold,
    required this.usesObjectness,
  });

  factory UavYoloConfig.fromJson(Map<String, dynamic> json) {
    return UavYoloConfig(
      enabled: json['enabled'] == true,
      modelAsset: (json['model_asset'] as String? ?? '').trim(),
      labelsAsset: (json['labels_asset'] as String? ?? '').trim(),
      scoreThreshold: (json['score_threshold'] as num? ?? 0.35).toDouble(),
      iouThreshold: (json['iou_threshold'] as num? ?? 0.45).toDouble(),
      usesObjectness: json['uses_objectness'] == true,
    );
  }

  final bool enabled;
  final String modelAsset;
  final String labelsAsset;
  final double scoreThreshold;
  final double iouThreshold;
  final bool usesObjectness;
}

class UavYoloDetection {
  const UavYoloDetection({
    required this.label,
    required this.score,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String label;
  final double score;
  final double left;
  final double top;
  final double right;
  final double bottom;
}

class UavYoloDetector {
  UavYoloDetector._({
    required Interpreter interpreter,
    required IsolateInterpreter isolateInterpreter,
    required UavYoloConfig config,
    required List<String> labels,
  }) : _interpreter = interpreter,
       _isolateInterpreter = isolateInterpreter,
       _config = config,
       _labels = labels;

  static const defaultConfigAsset = 'assets/models/uav_yolo_config.json';
  static const visdroneFinetunedConfigAsset =
      'assets/models/uav_visdrone_finetuned_config.json';
  static const roboflowDroneConfigAsset =
      'assets/models/uav_roboflow_drone_config.json';

  final Interpreter _interpreter;
  final IsolateInterpreter _isolateInterpreter;
  final UavYoloConfig _config;
  final List<String> _labels;

  static Future<UavYoloDetector?> tryCreate({
    String configAsset = defaultConfigAsset,
  }) async {
    final configJson = await rootBundle.loadString(configAsset);
    final config = UavYoloConfig.fromJson(
      jsonDecode(configJson) as Map<String, dynamic>,
    );
    if (!config.enabled || config.modelAsset.isEmpty) {
      return null;
    }

    final labels = await _loadLabels(config.labelsAsset);
    final interpreter = await Interpreter.fromAsset(
      config.modelAsset,
      options: _interpreterOptions(),
    );
    final isolateInterpreter = await IsolateInterpreter.create(
      address: interpreter.address,
    );
    return UavYoloDetector._(
      interpreter: interpreter,
      isolateInterpreter: isolateInterpreter,
      config: config,
      labels: labels,
    );
  }

  /// モデルファイルパスとラベルファイルパスを直接指定して生成する。
  /// JSON 設定ファイルが不要な場合に使用する。
  static Future<UavYoloDetector?> tryCreateFromPaths({
    required String modelAsset,
    required String labelsAsset,
    double scoreThreshold = 0.35,
    double iouThreshold = 0.45,
    bool usesObjectness = false,
  }) async {
    final config = UavYoloConfig(
      enabled: true,
      modelAsset: modelAsset,
      labelsAsset: labelsAsset,
      scoreThreshold: scoreThreshold,
      iouThreshold: iouThreshold,
      usesObjectness: usesObjectness,
    );
    final labels = await _loadLabels(config.labelsAsset);
    final interpreter = await Interpreter.fromAsset(
      config.modelAsset,
      options: _interpreterOptions(),
    );
    final isolateInterpreter = await IsolateInterpreter.create(
      address: interpreter.address,
    );
    return UavYoloDetector._(
      interpreter: interpreter,
      isolateInterpreter: isolateInterpreter,
      config: config,
      labels: labels,
    );
  }

  static Future<UavYoloDetector?> tryCreateFromCandidates(
    List<String> configAssets,
  ) async {
    Object? lastError;
    for (final asset in configAssets) {
      try {
        final detector = await tryCreate(configAsset: asset);
        if (detector != null) {
          return detector;
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) {
      throw lastError;
    }
    return null;
  }

  static InterpreterOptions _interpreterOptions() {
    final options = InterpreterOptions()..threads = 2;
    if (Platform.isAndroid) {
      // GPU delegate disabled due to OpenCL/OpenGL transpose shader errors on some devices.
      // options.addDelegate(GpuDelegateV2(options: GpuDelegateOptionsV2()));
    } else if (Platform.isIOS) {
      options.addDelegate(GpuDelegate(options: GpuDelegateOptions()));
    }
    return options;
  }

  static Future<List<String>> _loadLabels(String assetPath) async {
    if (assetPath.isEmpty) {
      return const [];
    }
    final raw = await rootBundle.loadString(assetPath);
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  String get description =>
      'YOLO TFLite (${_config.modelAsset.split('/').last}, score>=${_config.scoreThreshold.toStringAsFixed(2)})';

  Future<List<UavYoloDetection>> detectImageFile(String imagePath) async {
    final bytes = await File(imagePath).readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw Exception('YOLO 入力画像の読み込みに失敗しました。');
    }
    return detectImage(image);
  }

  Future<List<UavYoloDetection>> detectImage(img.Image image) async {
    final inputTensor = _interpreter.getInputTensor(0);
    final inputShape = inputTensor.shape;
    if (inputShape.length != 4) {
      throw Exception('YOLO input shape が想定外です: $inputShape');
    }

    final isNhwc = inputShape[3] == 3;
    final inputHeight = isNhwc ? inputShape[1] : inputShape[2];
    final inputWidth = isNhwc ? inputShape[2] : inputShape[3];
    final resized = img.copyResize(
      image,
      width: inputWidth,
      height: inputHeight,
      interpolation: img.Interpolation.linear,
    );

    final input = _buildInputTensor(resized, isNhwc: isNhwc);
    final outputShape = _interpreter.getOutputTensor(0).shape;
    final outputLength = outputShape.fold<int>(1, (acc, dim) => acc * dim);
    final output = Float32List(outputLength);

    await _isolateInterpreter.run(input.buffer, output.buffer);

    final rawDetections = _parseDetections(
      output.toList(),
      outputShape,
      originalWidth: image.width.toDouble(),
      originalHeight: image.height.toDouble(),
      modelWidth: inputWidth.toDouble(),
      modelHeight: inputHeight.toDouble(),
    );
    return _nonMaximumSuppression(rawDetections, _config.iouThreshold);
  }

  Float32List _buildInputTensor(img.Image image, {required bool isNhwc}) {
    final tensor = Float32List(image.width * image.height * 3);
    var i = 0;
    if (isNhwc) {
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final pixel = image.getPixel(x, y);
          tensor[i++] = pixel.b / 255.0;
          tensor[i++] = pixel.g / 255.0;
          tensor[i++] = pixel.r / 255.0;
        }
      }
      return tensor;
    }

    for (var channel = 0; channel < 3; channel++) {
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final pixel = image.getPixel(x, y);
          if (channel == 0) {
            tensor[i++] = pixel.b / 255.0;
          } else if (channel == 1) {
            tensor[i++] = pixel.g / 255.0;
          } else {
            tensor[i++] = pixel.r / 255.0;
          }
        }
      }
    }
    return tensor;
  }

  List<UavYoloDetection> _parseDetections(
    List<double> flat,
    List<int> shape, {
    required double originalWidth,
    required double originalHeight,
    required double modelWidth,
    required double modelHeight,
  }) {
    final matrix = _toBoxMajorMatrix(flat, shape);
    final detections = <UavYoloDetection>[];

    for (final row in matrix) {
      if (row.length < 5) {
        continue;
      }

      double objectness = 1.0;
      int classStart = 4;
      if (_config.usesObjectness && row.length >= 6) {
        objectness = row[4];
        classStart = 5;
      }

      if (row.length <= classStart) {
        continue;
      }

      var bestIndex = 0;
      var bestScore = double.negativeInfinity;
      for (var i = classStart; i < row.length; i++) {
        if (row[i] > bestScore) {
          bestScore = row[i];
          bestIndex = i - classStart;
        }
      }

      final finalScore = objectness * bestScore;
      if (finalScore < _config.scoreThreshold) {
        continue;
      }

      final centerX = row[0] * originalWidth / modelWidth;
      final centerY = row[1] * originalHeight / modelHeight;
      final width = row[2] * originalWidth / modelWidth;
      final height = row[3] * originalHeight / modelHeight;

      final left = math.max(0.0, centerX - width / 2).toDouble();
      final top = math.max(0.0, centerY - height / 2).toDouble();
      final right = math.min(originalWidth, centerX + width / 2).toDouble();
      final bottom =
          math.min(originalHeight, centerY + height / 2).toDouble();

      detections.add(
        UavYoloDetection(
          label: _labelForClass(bestIndex),
          score: finalScore,
          left: left,
          top: top,
          right: right,
          bottom: bottom,
        ),
      );
    }

    detections.sort((a, b) => b.score.compareTo(a.score));
    return detections;
  }

  List<List<double>> _toBoxMajorMatrix(List<double> flat, List<int> shape) {
    if (shape.length == 3 && shape[0] == 1) {
      final first = shape[1];
      final second = shape[2];
      if (first <= second) {
        return _transposeRows(flat, rows: first, cols: second);
      }
      return _rows(flat, rows: first, cols: second);
    }

    if (shape.length == 2) {
      final first = shape[0];
      final second = shape[1];
      if (first <= second) {
        return _transposeRows(flat, rows: first, cols: second);
      }
      return _rows(flat, rows: first, cols: second);
    }

    throw Exception('YOLO output shape が想定外です: $shape');
  }

  List<List<double>> _rows(List<double> flat, {required int rows, required int cols}) {
    final matrix = <List<double>>[];
    for (var row = 0; row < rows; row++) {
      final start = row * cols;
      matrix.add(flat.sublist(start, start + cols));
    }
    return matrix;
  }

  List<List<double>> _transposeRows(
    List<double> flat, {
    required int rows,
    required int cols,
  }) {
    final matrix = List.generate(cols, (_) => List.filled(rows, 0.0));
    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        matrix[col][row] = flat[row * cols + col];
      }
    }
    return matrix;
  }

  String _labelForClass(int classIndex) {
    if (classIndex < _labels.length) {
      return _labels[classIndex];
    }
    return 'class_$classIndex';
  }

  List<UavYoloDetection> _nonMaximumSuppression(
    List<UavYoloDetection> detections,
    double iouThreshold,
  ) {
    final kept = <UavYoloDetection>[];

    for (final candidate in detections) {
      var shouldKeep = true;
      for (final selected in kept) {
        if (candidate.label != selected.label) {
          continue;
        }
        if (_iou(candidate, selected) > iouThreshold) {
          shouldKeep = false;
          break;
        }
      }
      if (shouldKeep) {
        kept.add(candidate);
      }
    }

    return kept;
  }

  double _iou(UavYoloDetection a, UavYoloDetection b) {
    final left = math.max(a.left, b.left);
    final top = math.max(a.top, b.top);
    final right = math.min(a.right, b.right);
    final bottom = math.min(a.bottom, b.bottom);

    final intersectionWidth = math.max(0, right - left);
    final intersectionHeight = math.max(0, bottom - top);
    final intersection = intersectionWidth * intersectionHeight;
    if (intersection <= 0) {
      return 0;
    }

    final areaA = math.max(0, a.right - a.left) * math.max(0, a.bottom - a.top);
    final areaB = math.max(0, b.right - b.left) * math.max(0, b.bottom - b.top);
    final union = areaA + areaB - intersection;
    if (union <= 0) {
      return 0;
    }
    return intersection / union;
  }

  void dispose() {
    _isolateInterpreter.close();
    _interpreter.close();
  }
}
