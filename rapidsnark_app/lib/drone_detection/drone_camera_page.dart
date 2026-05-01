import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'detection_state.dart';
import 'drone_detector_provider.dart';

// ── エントリポイント ──────────────────────────────────────────────────────────

/// Riverpod スコープを提供してページを起動する。
/// `main()` で `ProviderScope` を wrap していない場合はこのウィジェットを使用する。
class DroneCameraPageEntry extends StatelessWidget {
  const DroneCameraPageEntry({super.key});

  @override
  Widget build(BuildContext context) => const ProviderScope(child: DroneCameraPage());
}

// ── メインページ ─────────────────────────────────────────────────────────────

/// カメラプレビューにリアルタイム YOLO 検出オーバーレイを重ねるページ。
class DroneCameraPage extends ConsumerStatefulWidget {
  const DroneCameraPage({super.key});

  @override
  ConsumerState<DroneCameraPage> createState() => _DroneCameraPageState();
}

class _DroneCameraPageState extends ConsumerState<DroneCameraPage>
    with WidgetsBindingObserver {
  CameraController? _cameraController;
  bool _cameraReady = false;
  String _cameraError = '';

  // モデルが ready になったらストリームを開始するフラグ
  bool _streamStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final ctrl = _cameraController;
    if (ctrl != null) {
      if (ctrl.value.isStreamingImages) ctrl.stopImageStream();
      ctrl.dispose();
    }
    super.dispose();
  }

  // アプリがバックグラウンドに移行したらカメラを停止
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final ctrl = _cameraController;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      if (ctrl.value.isStreamingImages) ctrl.stopImageStream();
    } else if (state == AppLifecycleState.resumed) {
      _restartStream();
    }
  }

  // ── カメラ初期化 ──────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _cameraError = 'カメラが見つかりません。');
        return;
      }

      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final ctrl = CameraController(
        camera,
        ResolutionPreset.medium,   // 720p: 推論速度と解像度のバランス
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }

      setState(() {
        _cameraController = ctrl;
        _cameraReady = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cameraError = 'カメラ初期化エラー: $e');
    }
  }

  // ── カメラストリーム ──────────────────────────────────────────────────────

  void _startStreamIfReady(DroneDetectionState detectorState) {
    final ctrl = _cameraController;
    if (!_cameraReady || ctrl == null) return;
    if (!detectorState.isReady) return;
    if (_streamStarted || ctrl.value.isStreamingImages) return;

    _streamStarted = true;
    ctrl.startImageStream((frame) {
      // Riverpod プロバイダにフレームを渡す（推論中はスキップされる）
      ref.read(droneDetectorProvider.notifier).processFrame(frame, ctrl.description.sensorOrientation);
    });
  }

  void _restartStream() {
    _streamStarted = false;
    _startStreamIfReady(ref.read(droneDetectorProvider));
  }

  // ── ビルド ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final detectorState = ref.watch(droneDetectorProvider);

    // モデルが ready になり次第ストリーム開始
    _startStreamIfReady(detectorState);

    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('ドローン リアルタイム検出'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (detectorState.latencyMs != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${detectorState.latencyMs!.toStringAsFixed(0)} ms',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 13,
                    fontFeatures: [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ① カメラプレビューと ② オーバーレイを同じアスペクト比のコンテナにまとめる
          if (_cameraError.isNotEmpty)
            Center(
              child: Text(
                _cameraError,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            )
          else if (!_cameraReady || _cameraController == null)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 12),
                  Text('カメラを初期化しています...', style: TextStyle(color: Colors.white70)),
                ],
              ),
            )
          else
            Center(
              child: AspectRatio(
                aspectRatio: isLandscape
                    ? _cameraController!.value.aspectRatio
                    : (1 / _cameraController!.value.aspectRatio),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CameraPreview(_cameraController!),
                    if (detectorState.isReady)
                      _BoundingBoxOverlay(detections: detectorState.detections),
                  ],
                ),
              ),
            ),

          // ③ ステータスバー（下部）
          Align(
            alignment: Alignment.bottomCenter,
            child: _StatusBar(state: detectorState),
          ),
        ],
      ),
    );
  }
}

// ── バウンディングボックスオーバーレイ ────────────────────────────────────────

class _BoundingBoxOverlay extends StatelessWidget {
  const _BoundingBoxOverlay({required this.detections});

  final List<DroneDetection> detections;

  @override
  Widget build(BuildContext context) {
    if (detections.isEmpty) return const SizedBox.shrink();

    return CustomPaint(
      painter: _BoxPainter(detections: detections),
    );
  }
}

class _BoxPainter extends CustomPainter {
  const _BoxPainter({required this.detections});

  final List<DroneDetection> detections;

  @override
  void paint(Canvas canvas, Size size) {
    // Gentle Design: Thin earth color (pale green/brown), e.g. pale sage green or ivory.
    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = const Color(0xFFB0C4B1); // Pale sage green

    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x33B0C4B1);

    final labelBgPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xCCB0C4B1);

    const labelStyle = TextStyle(
      color: Colors.black87, // Darker text for readability on pale background
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );

    for (final d in detections) {
      // 正規化座標 → 画面座標
      final rect = Rect.fromLTRB(
        d.box.left   * size.width,
        d.box.top    * size.height,
        d.box.right  * size.width,
        d.box.bottom * size.height,
      );

      // Rounded corners for the bounding box
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12.0));

      canvas.drawRRect(rrect, fillPaint);
      canvas.drawRRect(rrect, boxPaint);

      // ラベル テキスト
      final label = '${d.label}  ${(d.score * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout(maxWidth: size.width);

      final labelRect = Rect.fromLTWH(
        rect.left,
        rect.top - tp.height - 8,
        tp.width + 12,
        tp.height + 6,
      );
      
      // Rounded corners for the label chip
      final labelRRect = RRect.fromRectAndRadius(labelRect, const Radius.circular(8.0));
      canvas.drawRRect(labelRRect, labelBgPaint);
      tp.paint(canvas, Offset(rect.left + 6, rect.top - tp.height - 5));
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.detections != detections;
}

// ── ステータスバー ────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.state});

  final DroneDetectionState state;

  @override
  Widget build(BuildContext context) {
    final String message;
    final Color color;

    switch (state.status) {
      case DetectorStatus.loading:
        message = 'モデルを読み込んでいます...';
        color = Colors.amber;
      case DetectorStatus.error:
        message = state.errorMessage ?? 'エラー';
        color = Colors.red;
      case DetectorStatus.ready:
        final n = state.detections.length;
        message = n == 0
            ? 'ドローンは検出されていません'
            : 'ドローン $n 機を検出しました';
        color = n > 0 ? Colors.greenAccent : Colors.white70;
    }

    return Container(
      width: double.infinity,
      color: Colors.black54,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            if (state.status == DetectorStatus.loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  color: Colors.amber,
                  strokeWidth: 2,
                ),
              )
            else if (state.detections.isNotEmpty)
              const Icon(Icons.location_on, color: Colors.greenAccent, size: 16)
            else
              const Icon(Icons.search, color: Colors.white54, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: color, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
