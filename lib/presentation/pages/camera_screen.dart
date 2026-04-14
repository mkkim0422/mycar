import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/models/parking_data.dart';
import '../../data/repositories/ocr_repository.dart';
import '../../data/repositories/parking_repository.dart';

/// 촬영 완료 후 결과를 담는 모델.
class CameraResult {
  final String zone;
  final String floor;
  final String photoPath;

  const CameraResult({
    required this.zone,
    required this.floor,
    required this.photoPath,
  });
}

/// 3단계: 전체 화면 카메라 + OCR 구역 인식 화면.
///
/// ## 사용 흐름
/// 1. 카메라 초기화 (후면 카메라)
/// 2. 사용자가 주차 표지판을 뷰파인더에 맞추고 촬영 버튼 클릭
/// 3. 사진을 앱 문서 디렉터리에 저장
/// 4. OcrRepository로 구역 텍스트 추출
/// 5. ParkingRepository로 결과 저장
/// 6. 결과 확인 바텀시트 표시 → Navigator.pop으로 결과 반환
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  // ── Dependencies ───────────────────────────────────────────────────────────
  final _ocrRepository = OcrRepository();
  final _parkingRepository = ParkingRepository();

  // ── Camera state ───────────────────────────────────────────────────────────
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;
  bool _permissionDenied = false;

  // ── UI state ───────────────────────────────────────────────────────────────
  bool _isProcessing = false;
  String _statusMessage = '주차 표지판을 가이드 안에 맞춰주세요';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _permissionDenied) {
      // 시스템 설정에서 권한을 허용하고 돌아온 경우 재시도
      setState(() => _permissionDenied = false);
      _initCamera();
      return;
    }
    // 앱이 백그라운드로 나갔다가 돌아올 때 카메라 재초기화
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  // ── Camera initialization ──────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _setStatus('사용 가능한 카메라가 없습니다.');
        return;
      }

      // 후면 카메라 우선
      final backCamera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();

      if (!mounted) return;
      setState(() {
        _controller = controller;
        _isCameraReady = true;
      });
    } on CameraException catch (e) {
      // 권한 거부: 설정 안내 화면으로 전환
      if (e.code == 'CameraAccessDenied' ||
          e.code == 'CameraAccessDeniedWithoutPrompt' ||
          e.code == 'CameraAccessRestricted' ||
          e.code == 'permissionDenied') {
        if (mounted) setState(() => _permissionDenied = true);
      } else {
        _setStatus('카메라 오류: ${e.description}');
      }
    }
  }

  // ── Capture & OCR flow ─────────────────────────────────────────────────────

  Future<void> _onCapture() async {
    if (!_isCameraReady || _isProcessing) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = '사진 분석 중...';
    });

    // 햅틱 피드백
    await HapticFeedback.mediumImpact();

    try {
      // 1. 사진 촬영
      final xFile = await controller.takePicture();

      // 2. 앱 고유 디렉터리에 복사 저장 (영구 보관)
      final savedPath = await _savePhoto(xFile.path);

      // 3. OCR 구역 인식
      _setStatus('구역 번호 인식 중...');
      final ocrResult = await _ocrRepository.recognizeZone(savedPath);

      final zone = ocrResult?.zone ?? '인식 실패';
      // floor는 구역 결과에서 층수 분리 (예: "B2" → floor="B2", zone="B2")
      // 더 정교한 분리는 향후 기압 센서와 연동
      final floor = _extractFloor(zone);

      // 4. ParkingRepository에 저장
      final data = ParkingData(
        floor: floor,
        zone: zone,
        photoPath: savedPath,
        timestamp: DateTime.now(),
      );
      await _parkingRepository.save(data);

      if (!mounted) return;

      // 5. 결과 바텀시트 표시
      await _showResultSheet(
        CameraResult(zone: zone, floor: floor, photoPath: savedPath),
      );
    } on CameraException catch (e) {
      _setStatus('촬영 오류: ${e.description}');
    } catch (e) {
      _setStatus('처리 중 오류가 발생했습니다.');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '주차 표지판을 가이드 안에 맞춰주세요';
        });
      }
    }
  }

  /// XFile 임시 경로 → 앱 문서 디렉터리로 복사 후 영구 경로 반환.
  Future<String> _savePhoto(String tempPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'parking_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = '${dir.path}/$fileName';
    await File(tempPath).copy(destPath);
    return destPath;
  }

  /// 인식된 구역 텍스트에서 층수 정보를 추출.
  /// 예: "B2" → "B2", "지하 2층" → "지하 2층", "A-12" → "-"
  String _extractFloor(String zone) {
    // 지하층 패턴
    if (RegExp(r'^B\d', caseSensitive: false).hasMatch(zone)) return zone;
    if (zone.contains('지하') || zone.contains('지상')) return zone;
    if (RegExp(r'^\d+F$', caseSensitive: false).hasMatch(zone)) return zone;
    // 구역만 있고 층수 없는 경우
    return '-';
  }

  // ── Result bottom sheet ────────────────────────────────────────────────────

  Future<void> _showResultSheet(CameraResult result) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      builder: (_) => _ResultBottomSheet(
        result: result,
        onConfirm: () {
          Navigator.of(context).pop(); // 바텀시트 닫기
          Navigator.of(context).pop(result); // CameraScreen 닫고 결과 반환
        },
        onRetry: () {
          Navigator.of(context).pop(); // 바텀시트만 닫기, 재촬영
        },
      ),
    );
  }

  void _setStatus(String msg) {
    if (mounted) setState(() => _statusMessage = msg);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) return _buildPermissionDeniedScreen();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. 카메라 프리뷰 (전체 화면 full-bleed)
          _buildCameraPreview(),

          // 2. 상단 앱바 오버레이
          _buildTopBar(),

          // 3. 중앙 가이드 프레임
          _buildGuideFrame(),

          // 4. 하단 컨트롤
          _buildBottomControls(),

          // 5. 처리 중 오버레이
          if (_isProcessing) _buildProcessingOverlay(),
        ],
      ),
    );
  }

  Widget _buildPermissionDeniedScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // 닫기 버튼
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
              ),
            ),

            const Spacer(),

            const Icon(
              Icons.no_photography_outlined,
              size: 72,
              color: Colors.white38,
            ),
            const SizedBox(height: 24),

            const Text(
              '카메라 권한이 필요합니다',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),

            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 48),
              child: Text(
                '주차 구역 촬영을 위해\n카메라 접근 권한을 허용해 주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 15,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 36),

            // 설정으로 이동 버튼
            GestureDetector(
              onTap: () => AppSettings.openAppSettings(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF0064FF),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Text(
                  '설정에서 권한 허용',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (!_isCameraReady || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return CameraPreview(_controller!);
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              // 닫기 버튼
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
              ),
              const Expanded(
                child: Text(
                  '주차 구역 촬영',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // 우측 여백 균형
              const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuideFrame() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 가이드 프레임 (코너 마커 스타일)
          SizedBox(
            width: 280,
            height: 160,
            child: CustomPaint(painter: _CornerFramePainter()),
          ),
          const SizedBox(height: 20),
          // 상태 메시지
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _statusMessage,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 촬영 버튼 (Toss 스타일: 파란색 원형)
              GestureDetector(
                onTap: _isProcessing ? null : _onCapture,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isProcessing
                        ? Colors.white.withValues(alpha: 0.4)
                        : const Color(0xFF0064FF),
                    boxShadow: _isProcessing
                        ? null
                        : [
                            BoxShadow(
                              color: const Color(0xFF0064FF).withValues(alpha: 0.4),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                  ),
                  child: _isProcessing
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : const Icon(
                          Icons.camera_alt_rounded,
                          color: Colors.white,
                          size: 32,
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _isProcessing ? '처리 중...' : '촬영',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProcessingOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.45),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF0064FF)),
            SizedBox(height: 16),
            Text(
              'AI가 구역 번호를 인식하고 있습니다...',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Result Bottom Sheet ──────────────────────────────────────────────────────

class _ResultBottomSheet extends StatelessWidget {
  final CameraResult result;
  final VoidCallback onConfirm;
  final VoidCallback onRetry;

  const _ResultBottomSheet({
    required this.result,
    required this.onConfirm,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final hasPhoto = result.photoPath.isNotEmpty;
    final isOcrFailed = result.zone == '인식 실패';

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 드래그 핸들
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE5E8EB),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // 촬영된 사진 썸네일
          if (hasPhoto)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(result.photoPath),
                width: double.infinity,
                height: 180,
                fit: BoxFit.cover,
              ),
            ),
          const SizedBox(height: 20),

          // 인식 결과 타이틀
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOcrFailed ? '구역 인식에 실패했습니다' : '주차 구역을 인식했습니다!',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: isOcrFailed ? const Color(0xFF8B95A1) : Colors.black,
                  ),
                ),
                const SizedBox(height: 8),
                if (!isOcrFailed) ...[
                  _InfoRow(label: '구역', value: result.zone),
                  if (result.floor != '-')
                    _InfoRow(label: '층수', value: result.floor),
                ],
                if (isOcrFailed)
                  const Text(
                    '표지판이 선명하게 보이도록 다시 촬영해 주세요.',
                    style: TextStyle(
                      fontSize: 14,
                      color: Color(0xFF8B95A1),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // 버튼 영역
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: isOcrFailed
                ? _FullButton(
                    label: '다시 촬영',
                    color: const Color(0xFF0064FF),
                    onTap: onRetry,
                  )
                : Row(
                    children: [
                      Expanded(
                        child: _FullButton(
                          label: '다시 촬영',
                          color: const Color(0xFFF2F4F6),
                          textColor: const Color(0xFF333D4B),
                          onTap: onRetry,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _FullButton(
                          label: '저장 완료',
                          color: const Color(0xFF0064FF),
                          onTap: onConfirm,
                        ),
                      ),
                    ],
                  ),
          ),

          // Safe area padding
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            '$label  ',
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF8B95A1),
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0064FF),
            ),
          ),
        ],
      ),
    );
  }
}

class _FullButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;

  const _FullButton({
    required this.label,
    required this.color,
    this.textColor = Colors.white,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ── Corner Frame Painter ─────────────────────────────────────────────────────

/// 뷰파인더 코너 마커를 그리는 CustomPainter.
/// 번호판/표지판 인식 UI에서 자주 쓰이는 Toss 스타일 가이드 프레임.
class _CornerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0064FF)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const cornerLength = 24.0;
    const radius = 8.0;

    final path = Path();

    // 좌상단
    path.moveTo(0, cornerLength);
    path.lineTo(0, radius);
    path.quadraticBezierTo(0, 0, radius, 0);
    path.lineTo(cornerLength, 0);

    // 우상단
    path.moveTo(size.width - cornerLength, 0);
    path.lineTo(size.width - radius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, radius);
    path.lineTo(size.width, cornerLength);

    // 우하단
    path.moveTo(size.width, size.height - cornerLength);
    path.lineTo(size.width, size.height - radius);
    path.quadraticBezierTo(size.width, size.height, size.width - radius, size.height);
    path.lineTo(size.width - cornerLength, size.height);

    // 좌하단
    path.moveTo(cornerLength, size.height);
    path.lineTo(radius, size.height);
    path.quadraticBezierTo(0, size.height, 0, size.height - radius);
    path.lineTo(0, size.height - cornerLength);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
