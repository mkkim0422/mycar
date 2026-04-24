import 'dart:async';
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/config/app_config.dart';
import '../../core/services/gemini_ocr_service.dart';
import '../../core/services/location_service.dart';
import '../../data/models/parking_data.dart';
import '../../data/repositories/parking_repository.dart';

/// 촬영 완료 후 결과를 담는 모델.
/// 좌표/주소는 위치 권한 거부·타임아웃·에뮬레이터 환경에서 null 일 수 있다.
class CameraResult {
  final String zone;
  final String floor;
  final String photoPath;
  final double? latitude;
  final double? longitude;
  final String? address;

  const CameraResult({
    required this.zone,
    required this.floor,
    required this.photoPath,
    this.latitude,
    this.longitude,
    this.address,
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
  final _parkingRepository = ParkingRepository();

  // ── Camera state ───────────────────────────────────────────────────────────
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isCameraReady = false;
  bool _permissionDenied = false;

  // ── UI state ───────────────────────────────────────────────────────────────
  bool _isProcessing = false;
  String _statusMessage = '기둥/표지판이 잘 보이도록 촬영해 주세요';

  /// 사용자가 "설정에서 권한 허용" 버튼을 눌러 외부(시스템 설정)로 나갔는지 여부.
  /// 이 플래그가 true인 상태에서 앱이 resumed될 때만 카메라를 재초기화한다.
  /// (거부 직후 OS 다이얼로그 닫힘으로 인한 resumed 이벤트에 반응해 재시도하면
  ///  권한 다이얼로그가 반복 호출되어 화면이 무한 깜빡이는 문제가 발생한다)
  bool _awaitingSettingsReturn = false;

  /// 촬영 시점에 시작된 위치 조회의 pending Future.
  /// 바텀시트를 즉시 열어 사용자 체감 지연을 제거하고, 저장 시점에 결과를 수거한다.
  /// GPS 조회가 사용자 입력(3~5초)보다 빨리 끝나면 대기 0초.
  Future<LocationSnapshot>? _pendingLocation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    // GPS 사전 워밍업 — 카메라 진입과 동시에 백그라운드로 위치 조회를 시작한다.
    // prewarm:true 로 권한이 없을 때는 프롬프트를 띄우지 않고 empty 를 반환해
    // "촬영 버튼을 누르는 순간" 권한 다이얼로그가 뜨도록 타이밍을 미룬다.
    // 프리뷰 로딩 + 프레이밍 + 촬영 + 층/구역 입력 시간(평균 3~8초) 동안
    // GPS 가 이미 수렴하므로 "저장" 시점의 체감 대기는 거의 0초.
    _pendingLocation = LocationService.fetchCurrent(prewarm: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 촬영/처리 중일 때는 OS 다이얼로그(위치 권한 등)로 인한 짧은 inactive→resumed
    // 토글이 일어나도 카메라를 재초기화하지 않는다. 안 그러면 controller dispose /
    // _initCamera 가 반복 호출되며 화면이 무한 리프레시되는 레이스가 발생한다.
    if (_isProcessing) return;

    if (state == AppLifecycleState.resumed && _permissionDenied) {
      // 사용자가 명시적으로 "설정에서 권한 허용" 버튼을 통해 외부로 나갔다가
      // 돌아온 경우에만 재시도한다. 그렇지 않으면 OS 권한 거부 다이얼로그 닫힘이
      // 트리거한 resumed 이벤트에 반응해 _initCamera 를 호출 → 또 거부 →
      // _permissionDenied = true → resumed → ... 무한 루프가 발생한다.
      if (!_awaitingSettingsReturn) return;
      _awaitingSettingsReturn = false;
      setState(() => _permissionDenied = false);
      _initCamera();
      return;
    }
    // 권한 거부 상태에선 아래 재초기화 분기로도 들어가지 않음 (컨트롤러 없음).
    if (_permissionDenied) return;

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
      _statusMessage = '사진 처리 중...';
    });

    // 햅틱 피드백
    await HapticFeedback.mediumImpact();

    try {
      // 1. 위치 조회 수거/재시도 전략.
      //    - initState 의 사전 워밍업(prewarm:true)이 권한 미부여로 empty 를
      //      반환했다면 지금 풀 플로우(권한 프롬프트 포함)로 재요청한다.
      //    - 이미 좌표가 있거나 아직 진행 중이면 그대로 재사용 → 체감 지연 0초.
      _pendingLocation = await _ensureLocationFuture(_pendingLocation);

      // 2. 사진 촬영
      final xFile = await controller.takePicture();

      // 3. 앱 고유 디렉터리에 복사 저장 (영구 보관)
      final savedPath = await _savePhoto(xFile.path);

      if (!mounted) return;

      // 4. Gemini Vision OCR — 구역/층 자동 인식 (실패해도 수동 입력 폴백).
      //    API 키가 설정돼 있을 때만 호출되며, GeminiOcrService 내부에서
      //    5초 타임아웃·예외 흡수가 일어나므로 여기선 별도 방어가 필요 없다.
      GeminiOcrResult? ocrHint;
      if (AppConfig.isGeminiConfigured) {
        _setStatus('AI가 구역 번호 인식 중...');
        ocrHint = await GeminiOcrService.extractZone(savedPath);
      }

      if (!mounted) return;

      // 5. 결과 바텀시트를 즉시 연다. 위치는 저장 시점(onConfirm)에 수거.
      //    사용자가 층/구역 입력하는 동안 백그라운드 GPS 조회가 진행되어
      //    실제 체감 대기 시간은 거의 0에 가까워진다.
      await _showResultSheet(
        CameraResult(
          zone: '',
          floor: '',
          photoPath: savedPath,
        ),
        ocrHint: ocrHint,
      );
    } on CameraException catch (e) {
      _setStatus('촬영 오류: ${e.description}');
    } catch (e) {
      _setStatus('처리 중 오류가 발생했습니다.');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '기둥/표지판이 잘 보이도록 촬영해 주세요';
        });
      }
    }
  }

  /// 촬영 시점에 사용할 위치 Future 를 확정한다.
  ///
  /// - 기존 Future 가 아직 진행 중 → 그대로 재사용 (사전 워밍업 효과 유지).
  /// - 기존 Future 가 **좌표 없이 끝났다면** (권한 미부여/서비스 꺼짐 등)
  ///   권한 프롬프트를 포함한 풀 플로우로 재요청한다.
  /// - 기존 Future 가 **유효한 좌표로 끝났으면** 그대로 재사용.
  /// - 아예 없으면 새로 시작.
  ///
  /// 반환은 항상 non-null Future 이며, 촬영 흐름을 막지 않도록 즉시 돌려준다.
  Future<Future<LocationSnapshot>> _ensureLocationFuture(
    Future<LocationSnapshot>? existing,
  ) async {
    if (existing == null) return LocationService.fetchCurrent();
    // 이미 완료됐는지 non-blocking 으로 확인하기 위해 즉시 timeout 으로 peek.
    //   - 미완료면 TimeoutException → 그대로 재사용 (await 을 벗어나지 않음)
    //   - 완료됐으면 결과 검사 후 필요 시 재요청
    try {
      final snap = await existing.timeout(Duration.zero);
      if (snap.hasCoords) return existing;
      return LocationService.fetchCurrent();
    } on TimeoutException {
      return existing;
    }
  }

  /// XFile 임시 경로 → 앱 문서 디렉터리로 복사 후 영구 경로 반환.
  ///
  /// [compute]를 사용하여 파일 I/O를 별도 Isolate에서 실행한다.
  /// 고해상도 사진(7~15MB)의 복사는 메인 스레드에서 수십 ms 블로킹을
  /// 유발할 수 있으며, 이 시점에 UI 프레임 드랍이 발생한다.
  Future<String> _savePhoto(String tempPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'parking_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = '${dir.path}/$fileName';
    await compute(_copyFileInIsolate, _CopyParams(tempPath, destPath));
    return destPath;
  }

  // ── Result bottom sheet ────────────────────────────────────────────────────

  Future<void> _showResultSheet(
    CameraResult result, {
    GeminiOcrResult? ocrHint,
  }) async {
    // 바텀시트 결과로 "저장 완료된 CameraResult" 를 받는다. null 이면 재촬영/취소.
    //
    // ⚠️ 이전 구현은 onConfirm 내부에서 Navigator.pop() 을 두 번 연속 호출했는데,
    //    async 저장 중에 시스템 back 이 눌리면 시트가 먼저 닫혀버려 두 번째 pop()
    //    이 Shell(루트) 을 제거 → Navigator 가 비어 앱이 바탕화면으로 튕기는 버그
    //    가 있었다. 아래 구조는 **시트 pop 은 sheetCtx**, **CameraScreen pop 은
    //    modal 종료 후 이 함수의 context** 로 책임을 분리해 race 를 원천 차단한다.
    final saved = await showModalBottomSheet<CameraResult>(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      // 키보드가 올라왔을 때 시트가 가려지지 않도록 높이를 동적으로 허용
      isScrollControlled: true,
      builder: (sheetCtx) => _ResultBottomSheet(
        result: result,
        // 촬영과 동시에 시작된 백그라운드 위치 Future 를 전달해,
        // 시트에서 역지오코딩된 주소를 실시간 표시한다.
        pendingLocation: _pendingLocation,
        // Gemini Vision OCR 힌트. null 이면 (실패/타임아웃/키 미설정) 수동 입력.
        ocrHint: ocrHint,
        onConfirm: (edited) async {
          // 저장 버튼 UX 원칙: 즉시 반응, 절대 블로킹 금지.
          //
          // 위치 조회가 미완료라도 **최대 1초만** 기다리고 진행한다. 이전엔
          // 8초까지 대기했는데 사용자 관점에서는 "저장을 눌렀는데 8초간 화면이
          // 먹통"으로 인지되어 앱이 크래시한 것처럼 보였다. 위치 없이 저장되면
          // latitude/longitude 가 null 로 남지만, 주소는 사용자가 직접 편집했을
          // 수 있으므로 edited.address 를 우선 사용한다.
          //
          // - 대부분의 경우: 사전 워밍업된 위치가 이미 완료 → 0초
          // - 느린 경우: 1초 대기 후 empty 로 폴백 → 위치 없이 저장
          // - 예외 발생: try/catch 로 흡수해 empty 로 진행 (크래시 차단)
          var loc = LocationSnapshot.empty;
          final pending = _pendingLocation;
          if (pending != null) {
            try {
              loc = await pending.timeout(
                const Duration(seconds: 1),
                onTimeout: () => LocationSnapshot.empty,
              );
            } catch (_) {
              // 위치 서비스가 예외를 던지는 경우에도 저장은 반드시 진행.
            }
          }

          final data = ParkingData(
            floor: edited.floor,
            zone: edited.zone,
            photoPath: edited.photoPath,
            timestamp: DateTime.now(),
            latitude: loc.latitude,
            longitude: loc.longitude,
            // 사용자가 수동으로 편집한 주소가 있으면 그것을 1순위로 사용.
            // 편집 안 했으면 역지오코딩 결과를, 그것도 없으면 null 로 저장
            // (나중에 홈 화면에서 주소만 업데이트하는 기능을 추가할 수 있다).
            address: edited.address ?? loc.address,
          );
          await _parkingRepository.save(data);

          // 시트만 닫으며 저장된 결과를 showModalBottomSheet 의 Future 에 전달.
          // CameraScreen pop 은 이 모달이 완전히 닫힌 뒤 아래쪽에서 처리한다.
          if (!sheetCtx.mounted) return;
          Navigator.of(sheetCtx).pop(edited);
        },
        onRetry: () {
          // 재촬영: 결과 없이 시트만 닫는다 → 아래 saved==null 분기로 감.
          Navigator.of(sheetCtx).pop();
        },
      ),
    );

    // 모달이 정상 닫힌 뒤 CameraScreen 을 닫는다. 이 시점에는 Navigator 최상단
    // 이 확실히 CameraScreen 이므로 Shell 을 잘못 pop 할 가능성이 없다.
    if (saved != null && mounted) {
      Navigator.of(context).pop(saved);
    }
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

            // 설정으로 이동 버튼 — 돌아왔을 때 카메라 재시도를 허용하는 플래그를 세팅.
            GestureDetector(
              onTap: () {
                _awaitingSettingsReturn = true;
                AppSettings.openAppSettings();
              },
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

}

// ── Result Bottom Sheet ──────────────────────────────────────────────────────

class _ResultBottomSheet extends StatefulWidget {
  final CameraResult result;
  final ValueChanged<CameraResult> onConfirm;
  final VoidCallback onRetry;

  /// 촬영과 동시에 시작된 백그라운드 위치 조회 Future.
  /// 시트가 열릴 때 await 하여 주소 라인에 바인딩한다.
  final Future<LocationSnapshot>? pendingLocation;

  /// Gemini Vision API 가 뽑아낸 층/구역 힌트. null 이면 자동 인식을
  /// 건너뛰고 사용자가 처음부터 수동 입력한다. non-null 이어도 사용자는
  /// 언제든 수정 가능 — 어디까지나 기본값 채움용이다.
  final GeminiOcrResult? ocrHint;

  const _ResultBottomSheet({
    required this.result,
    required this.onConfirm,
    required this.onRetry,
    required this.pendingLocation,
    required this.ocrHint,
  });

  @override
  State<_ResultBottomSheet> createState() => _ResultBottomSheetState();
}

class _ResultBottomSheetState extends State<_ResultBottomSheet> {
  // 층·구역은 완전한 수동 입력. 지상/지하는 토글.
  final _floorCtrl = TextEditingController();
  final _zoneCtrl = TextEditingController();

  /// 주소 입력 컨트롤러 — 자동 역지오코딩 결과를 초기값으로 받지만 사용자가
  /// 자유롭게 수정 가능하다. Nominatim/OSM 이 이면도로(예: 사성로75번길)를
  /// 등록하지 않은 케이스에서 "광일로" 같은 인접 메인 도로가 잘못 뜰 수 있어
  /// 수동 보정 UI 가 필수적이다.
  final _addressCtrl = TextEditingController();

  /// 사용자가 주소를 직접 편집했는지 추적. 편집 이후에는 비동기로 뒤늦게
  /// 도착하는 자동 주소로 덮어쓰지 않는다.
  bool _addressEditedByUser = false;

  /// 지상/지하 선택 상태. 기본은 "지하" (대부분의 주차장이 지하).
  bool _isBasement = true;

  /// 주소 조회 상태 — 초기 "조회 중..." 표시용.
  bool _addressLoading = true;

  @override
  void initState() {
    super.initState();
    _applyOcrHint();
    _awaitAddress();
  }

  /// Gemini Vision 이 반환한 힌트를 입력 필드 초기값으로 채운다.
  ///
  /// 힌트가 null 이거나 빈 문자열이면 해당 필드는 그대로 비워둔 채 사용자
  /// 수동 입력을 기다린다. 지상/지하 토글은 힌트가 있을 때만 덮어써,
  /// 힌트가 아예 없을 때는 기존 기본값(지하) 을 유지한다.
  void _applyOcrHint() {
    final hint = widget.ocrHint;
    if (hint == null) return;
    if (hint.floor.isNotEmpty) _floorCtrl.text = hint.floor;
    if (hint.zone.isNotEmpty) _zoneCtrl.text = hint.zone;
    _isBasement = hint.isBasement;
  }

  /// 촬영 시점에 시작된 GPS/역지오코딩 결과를 기다려 UI 에 반영한다.
  /// 카메라 화면 initState 에서 사전 워밍업을 시작하므로 대부분 시트 열림
  /// 시점에 이미 완료되어 즉시 주소가 표시된다. 예외 대비 7초 안전망.
  Future<void> _awaitAddress() async {
    final future = widget.pendingLocation;
    if (future == null) {
      if (mounted) setState(() => _addressLoading = false);
      return;
    }
    try {
      final loc = await future.timeout(const Duration(seconds: 7));
      if (!mounted) return;
      setState(() {
        // 사용자가 이미 편집했다면 자동 주소로 덮어쓰지 않는다.
        if (!_addressEditedByUser && (loc.address?.isNotEmpty ?? false)) {
          _addressCtrl.text = loc.address!;
        }
        _addressLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _addressLoading = false);
    }
  }

  @override
  void dispose() {
    _floorCtrl.dispose();
    _zoneCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  /// 층 입력값과 지상/지하 토글을 한국어 포맷 문자열로 합성.
  /// - 입력이 순수 숫자면 "지하 2층" 형태
  /// - 비어 있으면 "-" (층 정보 없음 표시)
  /// - 그 외 자유 텍스트는 "지하 B2" 처럼 prefix 만 붙인다
  String _composedFloor() {
    final raw = _floorCtrl.text.trim();
    if (raw.isEmpty) return '-';
    final prefix = _isBasement ? '지하' : '지상';
    if (RegExp(r'^\d+$').hasMatch(raw)) return '$prefix $raw층';
    return '$prefix $raw';
  }

  /// 저장 시 입력값으로 CameraResult 를 구성.
  /// 좌표는 onConfirm 콜백 측에서 pending location 으로부터 수거하지만,
  /// **주소는 사용자가 편집 가능**하므로 여기서 직접 넘긴다.
  void _handleConfirm() {
    final typedZone = _zoneCtrl.text.trim();
    final typedAddress = _addressCtrl.text.trim();
    widget.onConfirm(CameraResult(
      floor: _composedFloor(),
      zone: typedZone.isEmpty ? '-' : typedZone,
      photoPath: widget.result.photoPath,
      address: typedAddress.isEmpty ? null : typedAddress,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = widget.result.photoPath.isNotEmpty;

    return Padding(
      // 키보드가 올라올 때 시트를 위로 밀어 inputs 가 가려지지 않게 한다.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      // 컨텐츠가 가용 높이를 초과하면 내부에서 스크롤 → "Bottom overflowed" 바 제거.
      child: SingleChildScrollView(
        child: Container(
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

              // ── 촬영된 사진 (premium: 부드러운 그림자 + r=16) ─────────────
              if (hasPhoto)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(
                        File(widget.result.photoPath),
                        width: double.infinity,
                        height: 220,
                        // cover = 비율 유지(왜곡 없음). 프레임에 가득 차게 맞춘다.
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // ── 현재 위치 주소 (역지오코딩 결과, 편집 가능) ────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _AddressField(
                  controller: _addressCtrl,
                  loading: _addressLoading,
                  onUserEdit: () => _addressEditedByUser = true,
                ),
              ),

              const SizedBox(height: 16),

              // ── 지상/지하 토글 ───────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _ElevationToggle(
                  isBasement: _isBasement,
                  onChanged: (basement) =>
                      setState(() => _isBasement = basement),
                ),
              ),

              const SizedBox(height: 12),

              // ── 층 + 구역 입력 (full-width, 가로 배치) ────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: _InfoInput(
                        controller: _floorCtrl,
                        hint: '층',
                        textInputAction: TextInputAction.next,
                        // 층: 숫자 전용 패드
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _InfoInput(
                        controller: _zoneCtrl,
                        hint: '구역',
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _handleConfirm(),
                        // 구역: 숫자패드 디폴트 + 한영 전환 시 텍스트 입력 가능.
                        // visiblePassword 는 숫자패드를 기본 표시하면서
                        // IME 전환 버튼(🌐/한영)을 유지한다.
                        keyboardType: TextInputType.visiblePassword,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── 버튼 영역: 다시 촬영 / 저장 ──────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: _FullButton(
                        label: '다시 촬영',
                        color: const Color(0xFFF2F4F6),
                        textColor: const Color(0xFF333D4B),
                        onTap: widget.onRetry,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _FullButton(
                        label: '저장',
                        color: const Color(0xFF0064FF),
                        onTap: _handleConfirm,
                      ),
                    ),
                  ],
                ),
              ),

              // Safe area padding
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }
}

/// 지상/지하 선택 세그먼트 컨트롤 (Toss 스타일).
/// 선택된 쪽만 tossBlue 채움, 반대쪽은 연한 회색 배경.
class _ElevationToggle extends StatelessWidget {
  final bool isBasement;
  final ValueChanged<bool> onChanged;

  const _ElevationToggle({
    required this.isBasement,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ToggleCell(
              label: '지하',
              selected: isBasement,
              onTap: () => onChanged(true),
            ),
          ),
          Expanded(
            child: _ToggleCell(
              label: '지상',
              selected: !isBasement,
              onTap: () => onChanged(false),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleCell extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ToggleCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0064FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFF0064FF).withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : const Color(0xFF8B95A1),
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }
}

/// 추가정보 섹션의 입력 박스 — Toss 스타일 filled input.
class _InfoInput extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final TextInputAction textInputAction;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;

  const _InfoInput({
    required this.controller,
    required this.hint,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      keyboardType: keyboardType,
      textAlign: TextAlign.center,
      maxLength: 20,
      buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
      // 포커스 시 `SingleChildScrollView` 가 이 입력이 키보드 위로 부드럽게
      // 올라오도록 자동 스크롤한다. bottom 여유를 넉넉히 주어 버튼과 겹치지 않게.
      scrollPadding: const EdgeInsets.only(bottom: 120),
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: Color(0xFF191F28),
        letterSpacing: -0.2,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(
          color: Color(0xFF8B95A1),
          fontWeight: FontWeight.w500,
          fontSize: 15,
        ),
        filled: true,
        fillColor: const Color(0xFFF2F4F6),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF0064FF), width: 1.5),
        ),
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

// ── 주소 편집 필드 ──────────────────────────────────────────────────────────

/// 촬영 위치의 역지오코딩 주소를 보여주면서 **자유 편집 가능**한 입력 컴포넌트.
///
/// ## 왜 편집 가능해야 하는가
/// - OSM/Nominatim 은 한국 이면도로(예: "사성로75번길") 가 데이터에 없으면
///   가장 가까운 등록 도로(예: "광일로") 를 반환한다. 좌표가 정확해도 주소가
///   틀릴 수 있는 근본 한계다.
/// - 지하주차장처럼 GPS 가 닿지 않는 환경에서는 WiFi 기반 위치로 100m+ 오차가
///   발생해 인접 도로로 잘못 매칭되는 경우도 있다.
/// - 사용자가 직접 수정할 수 있어야 어떤 지오코더를 써도 "제대로 된 주소"를
///   보장할 수 있다.
class _AddressField extends StatefulWidget {
  final TextEditingController controller;
  final bool loading;
  final VoidCallback onUserEdit;

  const _AddressField({
    required this.controller,
    required this.loading,
    required this.onUserEdit,
  });

  @override
  State<_AddressField> createState() => _AddressFieldState();
}

class _AddressFieldState extends State<_AddressField> {
  @override
  void initState() {
    super.initState();
    // controller.text 변화에 따라 지우기 버튼 노출 여부를 갱신.
    widget.controller.addListener(_onCtrlChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onCtrlChanged);
    super.dispose();
  }

  void _onCtrlChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final loading = widget.loading;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E8EB), width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            loading
                ? Icons.location_searching_rounded
                : Icons.place_rounded,
            size: 16,
            color: loading
                ? const Color(0xFF8B95A1)
                : const Color(0xFF0064FF),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => widget.onUserEdit(),
              maxLines: 1,
              textInputAction: TextInputAction.next,
              scrollPadding: const EdgeInsets.only(bottom: 120),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333D4B),
                height: 1.4,
                letterSpacing: -0.2,
              ),
              decoration: InputDecoration(
                hintText: loading ? '위치 확인 중...' : '주소를 입력하세요',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF8B95A1),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          // 주소 지우기 버튼 — 자동 매칭이 완전히 틀렸을 때 빠르게 비우고 새로 입력.
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                widget.onUserEdit();
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: Color(0xFF8B95A1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Isolate 파일 복사 (Top-level 함수 필수) ──────────────────────────────────

/// [compute]에서 사용하는 파일 복사 파라미터.
class _CopyParams {
  final String src;
  final String dst;
  const _CopyParams(this.src, this.dst);
}

/// Isolate에서 실행되는 파일 복사 함수.
/// 메인 스레드 블로킹 없이 고해상도 사진을 앱 디렉터리로 복사한다.
void _copyFileInIsolate(_CopyParams params) {
  File(params.src).copySync(params.dst);
}
