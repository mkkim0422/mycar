// =============================================================================
// 파일: ocr_camera_screen.dart
// 목적: '내차어디' 앱 - 주차 구역 번호 자동 인식 (고정밀 OCR)
// 핵심: 원본 이미지 무가공 → ML Kit → 3중 좌표 변환 → 가이드라인 필터링
// =============================================================================
//
// ┌─────────────────────────────────────────────────────────┐
// │  아키텍처 요약 (Banned Path 없음)                         │
// │                                                         │
// │  1. 촬영된 원본 이미지를 픽셀 조작 없이 그대로 ML Kit에 전달  │
// │  2. ML Kit 반환 boundingBox를 수학적 좌표 변환으로 매핑      │
// │     ├─ Step 1: 회전 보정 (Rotation)                      │
// │     ├─ Step 2: 비율 보정 (Aspect Ratio / Letterbox)      │
// │     └─ Step 3: 스케일링 (Image → Screen)                 │
// │  3. 가이드라인 영역과 교차하는 텍스트 중 최대 면적 채택       │
// └─────────────────────────────────────────────────────────┘

import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

// =============================================================================
// 메인 카메라 OCR 화면
// =============================================================================
class OcrCameraScreen extends StatefulWidget {
  const OcrCameraScreen({super.key});

  @override
  State<OcrCameraScreen> createState() => _OcrCameraScreenState;
}

class _OcrCameraScreenState extends State<OcrCameraScreen>
    with WidgetsBindingObserver {
  // ---------------------------------------------------------------------------
  // 컨트롤러 & 인식기
  // ---------------------------------------------------------------------------
  CameraController? _cameraController;
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.korean, // 한국어+영문+숫자 동시 인식
  );

  // ---------------------------------------------------------------------------
  // 상태 변수
  // ---------------------------------------------------------------------------
  bool _isCameraReady = false;
  bool _isProcessing = false;
  String _recognizedZone = ''; // 최종 인식된 주차 구역

  // ---------------------------------------------------------------------------
  // 가이드라인(크롭박스) 크기 (논리적 픽셀)
  // 기존 UI의 가이드라인 크기와 동일하게 맞춰야 합니다.
  // ---------------------------------------------------------------------------
  static const double _guideWidth = 260.0;
  static const double _guideHeight = 100.0;

  // ---------------------------------------------------------------------------
  // 카메라 미리보기 영역의 실제 렌더링 크기를 추적하기 위한 Key
  // ---------------------------------------------------------------------------
  final GlobalKey _previewContainerKey = GlobalKey();

  // ==========================================================================
  // 라이프사이클
  // ==========================================================================
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _textRecognizer.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
      setState(() {
        _cameraController = null;
        _isCameraReady = false;
      });
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  // ==========================================================================
  // 카메라 초기화
  // ==========================================================================
  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      // 후면 카메라 우선 선택
      final rearCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        rearCamera,
        ResolutionPreset.high, // 1920×1080 or 1280×720 급
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.jpeg
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();

      // 세로 고정 (대부분의 주차장 촬영 시나리오)
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);

      if (!mounted) return;
      setState(() {
        _cameraController = controller;
        _isCameraReady = true;
      });
    } catch (e) {
      debugPrint('[OCR] 카메라 초기화 실패: $e');
    }
  }

  // ==========================================================================
  // ★★★ 핵심: 촬영 → ML Kit → 좌표 변환 → 필터링 ★★★
  // ==========================================================================
  Future<void> _captureAndRecognize() async {
    final controller = _cameraController;
    if (_isProcessing || controller == null || !controller.value.isInitialized) {
      return;
    }

    setState(() => _isProcessing = true);

    try {
      // -----------------------------------------------------------------------
      // 1단계: 촬영 (원본 그대로, 전처리 없음)
      // -----------------------------------------------------------------------
      final xFile = await controller.takePicture();

      // -----------------------------------------------------------------------
      // 2단계: 원본 이미지 해상도 읽기 (메타데이터만, 픽셀 조작 없음)
      // -----------------------------------------------------------------------
      final imageBytes = await File(xFile.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(imageBytes);
      final frameInfo = await codec.getNextFrame();
      final int rawImageWidth = frameInfo.image.width;   // 예: 4000
      final int rawImageHeight = frameInfo.image.height;  // 예: 3000
      frameInfo.image.dispose();
      codec.dispose();

      // -----------------------------------------------------------------------
      // 3단계: 회전 각도 결정
      //
      // Android 후면 카메라: sensorOrientation = 90 (센서가 가로로 장착됨)
      // iOS 후면 카메라: sensorOrientation = 90 (동일)
      // iOS는 takePicture()가 EXIF 회전을 적용한 이미지를 반환하는 경우가 많아
      // 실질적으로 rotation=0과 동일하게 동작할 수 있음.
      //
      // InputImage.fromFilePath()는 EXIF를 자동 파싱하므로
      // ML Kit 내부적으로는 올바르게 인식하지만,
      // 반환되는 boundingBox는 **원본 픽셀 좌표계** 기준임.
      // 따라서 우리가 직접 회전 변환을 수행해야 함.
      // -----------------------------------------------------------------------
      final int sensorDeg = controller.description.sensorOrientation;
      final InputImageRotation rotation = _degToRotation(sensorDeg);

      // -----------------------------------------------------------------------
      // 4단계: ML Kit 텍스트 인식 (원본 이미지 전체를 그대로 전달)
      //
      // ★ 이미지 크롭/이진화/흑백 변환 일절 없음 = UI 멈춤 Zero ★
      // -----------------------------------------------------------------------
      final inputImage = InputImage.fromFilePath(xFile.path);
      final RecognizedText recognizedText =
          await _textRecognizer.processImage(inputImage);

      // -----------------------------------------------------------------------
      // 5단계: 미리보기 영역(Preview Container)의 실제 렌더링 크기 취득
      // -----------------------------------------------------------------------
      final containerRenderBox = _previewContainerKey.currentContext
          ?.findRenderObject() as RenderBox?;
      if (containerRenderBox == null) return;
      final Size containerSize = containerRenderBox.size;

      // -----------------------------------------------------------------------
      // 6단계: 가이드라인 Rect 계산 (미리보기 컨테이너 좌표계 기준)
      // -----------------------------------------------------------------------
      final Rect guideRect = Rect.fromCenter(
        center: Offset(containerSize.width / 2, containerSize.height / 2),
        width: _guideWidth,
        height: _guideHeight,
      );

      // -----------------------------------------------------------------------
      // 7단계: 3중 좌표 변환 + 필터링 + 최대 면적 채택
      // -----------------------------------------------------------------------
      String? bestText;
      double bestArea = 0.0;

      for (final TextBlock block in recognizedText.blocks) {
        // ML Kit이 반환한 boundingBox (원본 이미지 픽셀 좌표)
        final Rect rawBox = block.boundingBox;

        // ★ 3중 변환: Rotation → Aspect Ratio → Scaling ★
        final Rect screenBox = _transformBoundingBox(
          rawBox: rawBox,
          rawImageWidth: rawImageWidth,
          rawImageHeight: rawImageHeight,
          rotation: rotation,
          containerSize: containerSize,
        );

        // 가이드라인 영역과 교차(Intersect) 여부 판정
        if (!guideRect.overlaps(screenBox)) continue;

        // 교차하는 텍스트 중 면적이 가장 큰 것을 채택
        final double area = screenBox.width * screenBox.height;
        if (area > bestArea) {
          bestArea = area;
          bestText = block.text.trim();
        }
      }

      // -----------------------------------------------------------------------
      // 8단계: 결과 반영
      // -----------------------------------------------------------------------
      if (bestText != null && bestText.isNotEmpty) {
        setState(() => _recognizedZone = bestText!);
        // TODO: 여기서 자동 입력칸에 값을 넣거나, 콜백으로 전달
        // widget.onZoneRecognized?.call(bestText);
      } else {
        setState(() => _recognizedZone = '');
      }

      // 임시 파일 정리
      File(xFile.path).delete().ignore();
    } catch (e) {
      debugPrint('[OCR] 인식 오류: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // ==========================================================================
  // ★★★ 3중 좌표 변환 함수 (이 프로젝트의 수학적 핵심) ★★★
  // ==========================================================================
  //
  // 입력: ML Kit boundingBox (원본 이미지 픽셀 좌표계, 예: 4000×3000)
  // 출력: 디바이스 화면의 미리보기 영역 내 논리 픽셀 좌표계
  //
  // ┌──────────────────────────────────────────────────────────────────┐
  // │  STEP 1 [회전]                                                   │
  // │  카메라 센서 원본(Landscape) → 디바이스 방향(Portrait)에 맞게 회전   │
  // │                                                                  │
  // │  STEP 2 [비율 보정]                                               │
  // │  회전된 이미지 비율 vs 미리보기 컨테이너 비율 차이 → 여백 오프셋      │
  // │                                                                  │
  // │  STEP 3 [스케일링]                                                │
  // │  보정된 좌표를 논리적 픽셀 크기로 최종 변환                          │
  // └──────────────────────────────────────────────────────────────────┘
  //
  Rect _transformBoundingBox({
    required Rect rawBox,
    required int rawImageWidth,
    required int rawImageHeight,
    required InputImageRotation rotation,
    required Size containerSize,
  }) {
    // =========================================================================
    // STEP 1: 회전 보정 (Rotation Correction)
    // =========================================================================
    //
    // ML Kit의 boundingBox는 원본 이미지의 픽셀 좌표계.
    // 원본은 센서 방향(보통 Landscape)이므로, 디바이스 방향(Portrait)에 맞게
    // 좌표를 회전 변환해야 합니다.
    //
    // 회전 변환 공식 (이미지를 시계 방향으로 θ° 회전):
    //
    //   0°:   (x, y) → (x, y)                  크기 유지: W × H
    //   90°:  (x, y) → (H − y, x)              크기 전환: H × W
    //   180°: (x, y) → (W − x, H − y)          크기 유지: W × H
    //   270°: (x, y) → (y, W − x)              크기 전환: H × W
    //
    // Rect(left, top, right, bottom) 변환 도출:
    //   각 꼭짓점(left,top)과 (right,bottom)을 개별 변환 후
    //   min/max로 새 Rect를 구성합니다.
    // =========================================================================

    double rotatedLeft, rotatedTop, rotatedRight, rotatedBottom;
    double uprightWidth, uprightHeight; // 회전 후 "바로 선" 이미지 크기

    final double w = rawImageWidth.toDouble();
    final double h = rawImageHeight.toDouble();

    switch (rotation) {
      // -----------------------------------------------------------------------
      // 0°: 회전 불필요 (이미지가 이미 올바른 방향)
      // -----------------------------------------------------------------------
      case InputImageRotation.rotation0deg:
        rotatedLeft   = rawBox.left;
        rotatedTop    = rawBox.top;
        rotatedRight  = rawBox.right;
        rotatedBottom = rawBox.bottom;
        uprightWidth  = w;
        uprightHeight = h;

      // -----------------------------------------------------------------------
      // 90° 시계방향 회전 (Android 후면 카메라의 가장 흔한 케이스)
      //
      // 원본 Landscape(W×H)의 점 (x,y)를 90° CW 회전하면:
      //   x' = H - y
      //   y' = x
      // 회전 후 이미지 크기: H × W (가로/세로 교환)
      //
      // Rect 변환:
      //   (left, top)   → (H - top,    left)
      //   (right, bottom) → (H - bottom, right)
      //   새 left   = min(H-top, H-bottom) = H - bottom
      //   새 top    = min(left, right)      = left
      //   새 right  = max(H-top, H-bottom) = H - top
      //   새 bottom = max(left, right)      = right
      // -----------------------------------------------------------------------
      case InputImageRotation.rotation90deg:
        rotatedLeft   = h - rawBox.bottom;
        rotatedTop    = rawBox.left;
        rotatedRight  = h - rawBox.top;
        rotatedBottom = rawBox.right;
        uprightWidth  = h; // 가로세로 교환
        uprightHeight = w;

      // -----------------------------------------------------------------------
      // 180° 회전
      //
      // (x, y) → (W - x, H - y), 크기 유지: W × H
      //
      // Rect 변환:
      //   새 left   = W - right
      //   새 top    = H - bottom
      //   새 right  = W - left
      //   새 bottom = H - top
      // -----------------------------------------------------------------------
      case InputImageRotation.rotation180deg:
        rotatedLeft   = w - rawBox.right;
        rotatedTop    = h - rawBox.bottom;
        rotatedRight  = w - rawBox.left;
        rotatedBottom = h - rawBox.top;
        uprightWidth  = w;
        uprightHeight = h;

      // -----------------------------------------------------------------------
      // 270° 시계방향 회전 (= 90° 반시계)
      //
      // (x, y) → (y, W - x), 회전 후 크기: H × W
      //
      // Rect 변환:
      //   새 left   = top
      //   새 top    = W - right
      //   새 right  = bottom
      //   새 bottom = W - left
      // -----------------------------------------------------------------------
      case InputImageRotation.rotation270deg:
        rotatedLeft   = rawBox.top;
        rotatedTop    = w - rawBox.right;
        rotatedRight  = rawBox.bottom;
        rotatedBottom = w - rawBox.left;
        uprightWidth  = h; // 가로세로 교환
        uprightHeight = w;
    }

    // =========================================================================
    // STEP 2: 비율 보정 (Aspect Ratio Correction) — Letterbox/Pillarbox 오프셋
    // =========================================================================
    //
    // 회전 후 "바로 선" 이미지 비율과 미리보기 컨테이너 비율이 다를 수 있습니다.
    //
    // 예시:
    //   회전 후 이미지: 3000 × 4000 (비율 0.75)
    //   미리보기 영역:  390 × 844  (비율 0.462)
    //
    // 이 경우 이미지가 더 넓으므로 → 너비 기준 맞춤(fitWidth)
    // → 상하에 빈 여백 발생 (Letterbox)
    //
    // 반대로 이미지가 더 좁으면 → 높이 기준 맞춤(fitHeight)
    // → 좌우에 빈 여백 발생 (Pillarbox)
    //
    // contain 모드 공식:
    //   scale = min(containerW / imageW, containerH / imageH)
    //   offsetX = (containerW - imageW × scale) / 2
    //   offsetY = (containerH - imageH × scale) / 2
    // =========================================================================

    final double imageAspect = uprightWidth / uprightHeight;
    final double containerAspect = containerSize.width / containerSize.height;

    late final double scale;
    late final double offsetX;
    late final double offsetY;

    if (containerAspect > imageAspect) {
      // 컨테이너가 이미지보다 가로로 넓음
      // → 높이에 맞추고, 좌우에 Pillarbox(여백) 발생
      scale = containerSize.height / uprightHeight;
      offsetX = (containerSize.width - uprightWidth * scale) / 2.0;
      offsetY = 0.0;
    } else {
      // 컨테이너가 이미지보다 세로로 김
      // → 너비에 맞추고, 상하에 Letterbox(여백) 발생
      scale = containerSize.width / uprightWidth;
      offsetX = 0.0;
      offsetY = (containerSize.height - uprightHeight * scale) / 2.0;
    }

    // =========================================================================
    // STEP 3: 스케일링 (Final Coordinate Mapping)
    // =========================================================================
    //
    // 회전 보정된 이미지 좌표에 scale을 곱하고 offset을 더하면
    // 미리보기 컨테이너의 논리적 픽셀 좌표계로 최종 변환됩니다.
    //
    // screenX = rotatedX × scale + offsetX
    // screenY = rotatedY × scale + offsetY
    // =========================================================================

    return Rect.fromLTRB(
      rotatedLeft   * scale + offsetX,
      rotatedTop    * scale + offsetY,
      rotatedRight  * scale + offsetX,
      rotatedBottom * scale + offsetY,
    );
  }

  // ==========================================================================
  // 유틸: sensorOrientation(도) → InputImageRotation 변환
  // ==========================================================================
  InputImageRotation _degToRotation(int sensorDeg) {
    switch (sensorDeg) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  // ==========================================================================
  // UI 빌드
  // ==========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isCameraReady ? _buildCameraView() : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text('카메라 준비 중...', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildCameraView() {
    final controller = _cameraController!;
    // controller.value.previewSize는 센서 기준(Landscape)이므로
    // Portrait 표시 시 width/height를 교환해서 사용합니다.
    final previewSize = controller.value.previewSize!;
    final double previewAspectRatio = previewSize.height / previewSize.width;

    return Stack(
      key: _previewContainerKey, // 이 Stack의 크기 = 미리보기 컨테이너 크기
      fit: StackFit.expand,
      children: [
        // === 카메라 미리보기 ===
        Center(
          child: AspectRatio(
            aspectRatio: previewAspectRatio,
            child: CameraPreview(controller),
          ),
        ),

        // === 가이드라인(크롭박스) 오버레이 ===
        _buildGuidelineOverlay(),

        // === 인식 결과 표시 ===
        if (_recognizedZone.isNotEmpty) _buildResultBanner(),

        // === 하단 촬영 버튼 ===
        _buildCaptureButton(),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // 가이드라인 UI: 중앙에 투명 사각형, 주변은 반투명 어둡게
  // --------------------------------------------------------------------------
  Widget _buildGuidelineOverlay() {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _GuidelinePainter(
          guideWidth: _guideWidth,
          guideHeight: _guideHeight,
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 인식 결과 배너
  // --------------------------------------------------------------------------
  Widget _buildResultBanner() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 24,
      right: 24,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF2E7D32),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.local_parking, color: Colors.white, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '주차 구역 인식 완료',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _recognizedZone,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 촬영 버튼
  // --------------------------------------------------------------------------
  Widget _buildCaptureButton() {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 32,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _isProcessing ? null : _captureAndRecognize,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isProcessing ? Colors.grey : Colors.white,
              border: Border.all(color: Colors.white54, width: 4),
            ),
            child: _isProcessing
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.black54,
                    ),
                  )
                : const Icon(
                    Icons.camera_alt,
                    color: Colors.black87,
                    size: 32,
                  ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 가이드라인 페인터: 중앙 투명 사각 + 주변 반투명 오버레이
// =============================================================================
class _GuidelinePainter extends CustomPainter {
  final double guideWidth;
  final double guideHeight;

  _GuidelinePainter({required this.guideWidth, required this.guideHeight});

  @override
  void paint(Canvas canvas, Size size) {
    // 가이드라인 영역 (화면 중앙)
    final Rect guideRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: guideWidth,
      height: guideHeight,
    );

    // 반투명 오버레이 (가이드라인 바깥)
    final overlayPaint = Paint()..color = Colors.black.withOpacity(0.55);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()
          ..addRRect(
              RRect.fromRectAndRadius(guideRect, const Radius.circular(12))),
      ),
      overlayPaint,
    );

    // 가이드라인 테두리
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(guideRect, const Radius.circular(12)),
      borderPaint,
    );

    // 네 모서리 강조선 (코너 마커)
    final cornerPaint = Paint()
      ..color = const Color(0xFF4CAF50) // 초록색 강조
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;

    const double cornerLen = 20.0;
    final double l = guideRect.left;
    final double t = guideRect.top;
    final double r = guideRect.right;
    final double b = guideRect.bottom;

    // 좌상단
    canvas.drawLine(Offset(l, t + cornerLen), Offset(l, t), cornerPaint);
    canvas.drawLine(Offset(l, t), Offset(l + cornerLen, t), cornerPaint);
    // 우상단
    canvas.drawLine(Offset(r - cornerLen, t), Offset(r, t), cornerPaint);
    canvas.drawLine(Offset(r, t), Offset(r, t + cornerLen), cornerPaint);
    // 좌하단
    canvas.drawLine(Offset(l, b - cornerLen), Offset(l, b), cornerPaint);
    canvas.drawLine(Offset(l, b), Offset(l + cornerLen, b), cornerPaint);
    // 우하단
    canvas.drawLine(Offset(r - cornerLen, b), Offset(r, b), cornerPaint);
    canvas.drawLine(Offset(r, b), Offset(r, b - cornerLen), cornerPaint);

    // 안내 텍스트
    final textPainter = TextPainter(
      text: const TextSpan(
        text: '주차 구역 번호를 사각형 안에 맞춰주세요',
        style: TextStyle(color: Colors.white70, fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        (size.width - textPainter.width) / 2,
        guideRect.bottom + 16,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _GuidelinePainter old) =>
      old.guideWidth != guideWidth || old.guideHeight != guideHeight;
}
