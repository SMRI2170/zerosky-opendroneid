import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../uav_yolo_detector.dart';
import 'detection_state.dart';

// ── 定数 ────────────────────────────────────────────────────────────────────

const _modelAsset  = 'assets/models/uav_yolo11n_uav.tflite';
const _labelsAsset = 'assets/models/uav_detector_labels.txt';

// ── プロバイダ ───────────────────────────────────────────────────────────────

/// ドローン検出器プロバイダ（Riverpod 3.x Notifier API）。
/// ページが破棄されると autoDispose で TFLite リソースを解放する。
final droneDetectorProvider =
    NotifierProvider.autoDispose<DroneDetectorNotifier, DroneDetectionState>(
  DroneDetectorNotifier.new,
);

// ── Notifier ─────────────────────────────────────────────────────────────────

class DroneDetectorNotifier
    extends Notifier<DroneDetectionState> {
  UavYoloDetector? _detector;
  bool _processing = false;

  // build() が初期状態を返す。副作用は Future.microtask で開始する。
  @override
  DroneDetectionState build() {
    ref.onDispose(() => _detector?.dispose());
    Future.microtask(_initialize);
    return DroneDetectionState.loading();
  }

  // ── 初期化 ──────────────────────────────────────────────────────────────

  Future<void> _initialize() async {
    try {
      final detector = await UavYoloDetector.tryCreateFromPaths(
        modelAsset: _modelAsset,
        labelsAsset: _labelsAsset,
        scoreThreshold: 0.20, // Lowered threshold temporarily for debugging
        iouThreshold: 0.45,
        usesObjectness: false,
      );

      if (detector == null) {
        state = state.copyWith(
          status: DetectorStatus.error,
          errorMessage: '$_modelAsset が見つかりません。assets に配置してください。',
        );
        return;
      }

      _detector = detector;
      state = state.copyWith(status: DetectorStatus.ready);
    } catch (e) {
      state = state.copyWith(
        status: DetectorStatus.error,
        errorMessage: 'モデル読み込みエラー: $e',
      );
    }
  }

  // ── フレーム処理 ─────────────────────────────────────────────────────────

  /// カメラストリームから受け取った YUV420 フレームを推論する。
  /// 推論中のフレームはスキップする（キューが詰まるのを防ぐ）。
  Future<void> processFrame(CameraImage frame, int sensorOrientation) async {
    final detector = _detector;
    if (_processing || detector == null || !state.isReady) return;

    _processing = true;
    final startedAt = DateTime.now();

    try {
      // ① YUV420 → RGB img.Image
      final rgbImage = _yuv420ToRgb(frame);

      // ② YOLO 推論（リサイズ・正規化・NMS は detector 内部で実施）
      final rawDetections = await detector.detectImage(rgbImage);

      // ③ 絶対座標 → 正規化座標 [0,1] に変換（sensorOrientationを考慮して回転）
      final normalized = rawDetections
          .take(10)
          .map((d) {
            double nxLeft   = d.left   / frame.width;
            double nxTop    = d.top    / frame.height;
            double nxRight  = d.right  / frame.width;
            double nxBottom = d.bottom / frame.height;

            double finalLeft = nxLeft;
            double finalTop = nxTop;
            double finalRight = nxRight;
            double finalBottom = nxBottom;

            // 画面の向き（ポートレート）に合わせてバウンディングボックスを回転させる
            if (sensorOrientation == 90) {
              finalLeft = 1.0 - nxBottom;
              finalTop = nxLeft;
              finalRight = 1.0 - nxTop;
              finalBottom = nxRight;
            } else if (sensorOrientation == 270) {
              finalLeft = nxTop;
              finalTop = 1.0 - nxRight;
              finalRight = nxBottom;
              finalBottom = 1.0 - nxLeft;
            }

            return DroneDetection(
              label: d.label,
              score: d.score,
              box: Rect.fromLTRB(
                math.max(0.0, math.min(1.0, finalLeft)),
                math.max(0.0, math.min(1.0, finalTop)),
                math.max(0.0, math.min(1.0, finalRight)),
                math.max(0.0, math.min(1.0, finalBottom)),
              ),
            );
          })
          .toList();

      state = state.copyWith(
        detections: normalized,
        latencyMs:
            DateTime.now().difference(startedAt).inMilliseconds.toDouble(),
      );
    } catch (e) {
      // フレーム単位のエラーはコンソールに出力
      print('Frame processing error: $e');
    } finally {
      _processing = false;
    }
  }

  // ── YUV420 → RGB 変換 ────────────────────────────────────────────────────

  img.Image _yuv420ToRgb(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final output = img.Image(width: w, height: h);

    final planeY = image.planes[0];
    final planeU = image.planes[1];
    final planeV = image.planes[2];

    final yRowStride    = planeY.bytesPerRow;
    final uvRowStride   = planeU.bytesPerRow;
    final uvPixelStride = planeU.bytesPerPixel ?? 1;

    for (var row = 0; row < h; row++) {
      final yBase  = row * yRowStride;
      final uvBase = (row >> 1) * uvRowStride;
      for (var col = 0; col < w; col++) {
        final uvOffset = uvBase + (col >> 1) * uvPixelStride;
        final yVal = planeY.bytes[yBase + col];
        final uVal = planeU.bytes[uvOffset];
        final vVal = planeV.bytes[uvOffset];

        // BT.601 YUV → RGB
        final r = _clamp((yVal + 1.402   * (vVal - 128)).round());
        final g = _clamp(
            (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128)).round());
        final b = _clamp((yVal + 1.772   * (uVal - 128)).round());

        output.setPixelRgba(col, row, r, g, b, 255);
      }
    }
    return output;
  }

  int _clamp(int v) => math.max(0, math.min(255, v));
}
