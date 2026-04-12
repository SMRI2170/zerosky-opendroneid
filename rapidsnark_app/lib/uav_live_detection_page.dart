import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'uav_yolo_detector.dart';

class UavLiveDetectionPage extends StatefulWidget {
  const UavLiveDetectionPage({
    super.key,
    required this.detector,
    required this.detectorLabel,
  });

  final UavYoloDetector? detector;
  final String detectorLabel;

  @override
  State<UavLiveDetectionPage> createState() => _UavLiveDetectionPageState();
}

class _UavLiveDetectionPageState extends State<UavLiveDetectionPage> {
  CameraController? _controller;
  bool _initializing = true;
  bool _processing = false;
  String _status = 'カメラを初期化しています...';
  List<UavYoloDetection> _detections = const [];
  Size? _lastImageSize;
  DateTime? _lastInferenceAt;
  Duration? _lastInferenceDuration;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeCamera());
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (entry) => entry.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _controller = controller;
        _initializing = false;
        _status = widget.detector == null
            ? 'YOLO モデルが未設定です。ライブ映像は表示できますが検知は動きません。'
            : 'ライブ映像を解析しています...';
      });

      if (widget.detector != null) {
        await controller.startImageStream(_onCameraImage);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _initializing = false;
        _status = 'ライブ検知の初期化エラー: $error';
      });
    }
  }

  Future<void> _onCameraImage(CameraImage image) async {
    if (_processing || widget.detector == null) {
      return;
    }

    final now = DateTime.now();
    if (_lastInferenceAt != null &&
        now.difference(_lastInferenceAt!) < const Duration(milliseconds: 350)) {
      return;
    }

    _processing = true;
    _lastInferenceAt = now;
    final startedAt = DateTime.now();
    _lastImageSize = Size(image.width.toDouble(), image.height.toDouble());

    try {
      final rgbImage = _cameraImageToRgb(image);
      final detections = await widget.detector!.detectImage(rgbImage);
      if (!mounted) {
        return;
      }

      setState(() {
        _detections = detections.take(6).toList();
        _lastInferenceDuration = DateTime.now().difference(startedAt);
        _status = detections.isEmpty
            ? 'UAV 候補はまだ検出されていません。'
            : 'UAV 候補を ${detections.length} 件検出しました。';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'ライブ推論エラー: $error';
      });
    } finally {
      _processing = false;
    }
  }

  img.Image _cameraImageToRgb(CameraImage image) {
    final output = img.Image(width: image.width, height: image.height);
    final planeY = image.planes[0];
    final planeU = image.planes[1];
    final planeV = image.planes[2];

    for (var y = 0; y < image.height; y++) {
      final uvRow = planeU.bytesPerRow * (y >> 1);
      final yRow = planeY.bytesPerRow * y;
      for (var x = 0; x < image.width; x++) {
        final uvIndex = uvRow + (x >> 1) * planeU.bytesPerPixel!;
        final yValue = planeY.bytes[yRow + x];
        final uValue = planeU.bytes[uvIndex];
        final vValue = planeV.bytes[uvIndex];

        final r = (yValue + 1.402 * (vValue - 128)).round();
        final g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).round();
        final b = (yValue + 1.772 * (uValue - 128)).round();

        output.setPixelRgba(
          x,
          y,
          _clampColor(r),
          _clampColor(g),
          _clampColor(b),
          255,
        );
      }
    }
    return output;
  }

  int _clampColor(int value) => math.max(0, math.min(255, value));

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      if (controller.value.isStreamingImages) {
        controller.stopImageStream();
      }
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final lastLatency = _lastInferenceDuration == null
        ? 'まだ未実行'
        : '${_lastInferenceDuration!.inMilliseconds} ms';

    return Scaffold(
      appBar: AppBar(title: const Text('UAV Live YOLO')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              child: _initializing
                  ? const Center(child: CircularProgressIndicator())
                  : controller == null || !controller.value.isInitialized
                  ? const Center(
                      child: Text(
                        'カメラを初期化できませんでした',
                        style: TextStyle(color: Colors.white),
                      ),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(controller),
                        if (_lastImageSize != null)
                          CustomPaint(
                            painter: _DetectionOverlayPainter(
                              detections: _detections,
                              imageSize: _lastImageSize!,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFFF5F4EC),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'バックエンド: ${widget.detectorLabel}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF12312E),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _status,
                  style: const TextStyle(
                    color: Color(0xFF3B4D4A),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '推論レイテンシ: $lastLatency',
                  style: const TextStyle(
                    color: Color(0xFF4E6762),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                if (_detections.isEmpty)
                  const Text(
                    '検出結果はまだありません',
                    style: TextStyle(color: Color(0xFF4E6762)),
                  )
                else
                  ..._detections.map(
                    (detection) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${detection.label}  score=${detection.score.toStringAsFixed(2)}  box=(${detection.left.toStringAsFixed(0)}, ${detection.top.toStringAsFixed(0)})-(${detection.right.toStringAsFixed(0)}, ${detection.bottom.toStringAsFixed(0)})',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Color(0xFF334643),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetectionOverlayPainter extends CustomPainter {
  const _DetectionOverlayPainter({
    required this.detections,
    required this.imageSize,
  });

  final List<UavYoloDetection> detections;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;
    final boxPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final bgPaint = Paint()
      ..color = Colors.black87
      ..style = PaintingStyle.fill;

    for (final detection in detections) {
      final rect = Rect.fromLTRB(
        detection.left * scaleX,
        detection.top * scaleY,
        detection.right * scaleX,
        detection.bottom * scaleY,
      );
      canvas.drawRect(rect, boxPaint);

      final textPainter = TextPainter(
        text: TextSpan(
          text:
              '${detection.label} ${detection.score.toStringAsFixed(2)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width * 0.8);

      final bgRect = Rect.fromLTWH(
        rect.left,
        math.max(0, rect.top - textPainter.height - 6),
        textPainter.width + 8,
        textPainter.height + 4,
      );
      canvas.drawRect(bgRect, bgPaint);
      textPainter.paint(canvas, Offset(bgRect.left + 4, bgRect.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionOverlayPainter oldDelegate) {
    return oldDelegate.detections != detections ||
        oldDelegate.imageSize != imageSize;
  }
}
