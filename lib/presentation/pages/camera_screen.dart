import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app_settings/app_settings.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// 주차 위치 등록 — 순정 카메라 화면 (V11.4 = V11.3 + 번호판 인접 dropout 강화).
///
/// ## 화면 구성 (4 요소)
///   1) CameraPreview
///   2) 중앙 정적 가이드 박스 (모서리 마커)
///   3) 큰 원형 셔터 (하단)
///   4) 최종 1개 매칭 위에만 초록 AR 박스
///
/// ## V11.3 → V11.4 변경 사항
///   - v12 의 Pass A (floor/zone 분리) 전체 폐기
///   - v12 의 카메라 줌 (핀치/인디케이터) 전체 폐기
///   - v12.1 의 priority-aware stability 폐기 (단순 stability 로 복귀)
///   - **번호판 dropout 강화**: 단일 줄 + **인접 두 줄 합쳐서도** 번호판 정규식
///     매치 → 두 줄 다 dropout. "12 ¶ 가3456" 처럼 분리 인식돼서 "12" 가
///     zone 으로 잘못 채택되던 문제 차단.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  /// 앱 시작 시 카메라 목록을 미리 조회해 캐싱한다(카메라를 열지는 않음 —
  /// 권한 불필요). 첫 카메라 진입 시 `availableCameras()` 채널 왕복을 없애
  /// 프리뷰 표시를 앞당긴다. 실패해도 진입 시 다시 조회하므로 무시.
  static Future<void> warmUpCameras() async {
    try {
      _CameraScreenState._cachedCameras ??= await availableCameras();
    } catch (_) {}
  }

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  // ── Camera ─────────────────────────────────────────────────────────────────
  CameraController? _controller;
  TextRecognizer? _recognizer;
  bool _isCameraReady = false;
  bool _permissionDenied = false;
  bool _awaitingSettingsReturn = false;

  bool _isProcessing = false;
  bool _isCapturing = false;
  bool _popped = false;

  /// 위젯 콜드 스타트 → lifecycle inactive↔resumed 토글 중에
  /// `_initCamera()` 가 2번 동시에 호출돼서 두 controller 가 카메라 락을 동시에
  /// 잡으려다 `CameraException(disposed CameraController)` 빨간 화면이 뜨던
  /// race condition 방지용 reentrancy guard.
  bool _initInProgress = false;

  // ── 핀치 줌 ────────────────────────────────────────────────────────────────
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  double _baseScaleZoom = 1.0; // onScaleStart 시 _currentZoom 스냅샷

  // ── 탭 포커스 ─────────────────────────────────────────────────────────────
  /// 사용자가 탭한 화면 좌표(포커스 링 표시용). null 이면 숨김.
  Offset? _focusIndicator;
  Timer? _focusTimer; // 포커스 링 자동 숨김 타이머

  // ── 좌표 측정 + AR 상태 ────────────────────────────────────────────────────
  final _previewContainerKey = GlobalKey();
  Rect? _arBox;
  String? _lastMatchedZone;
  String? _lastMatchedFloorType; // '지하' / '지상' / null
  String? _lastMatchedFloorNum; // '1'~'9' / null
  double _lastUprightW = 0;
  double _lastUprightH = 0;

  /// boundingBox(OCR 좌표) → 프리뷰(cov) 좌표로 옮길 때 더하는 오프셋(업라이트).
  /// 가운데 crop 경로에서 crop 영역의 좌상단 위치. 그 외 경로는 0.
  double _ocrOffX = 0;
  double _ocrOffY = 0;

  /// 이번 프레임을 가이드 영역으로 crop 해 보냈는지. true 면 가이드 교차 필터를
  /// 건너뛴다(crop 자체가 가이드 영역이라 들어온 라인이 곧 가이드 내 라인).
  bool _ocrCroppedToGuide = false;

  /// ML Kit 이 본 입력 이미지(업라이트)의 중심 — boundingBox 와 같은 좌표계.
  /// "가운데 번호 우선 선택"의 거리 기준점.
  Offset _ocrCenter = Offset.zero;

  // ── 상수 ───────────────────────────────────────────────────────────────────
  static const double _guideBoxWidth = 280.0;
  static const double _guideBoxHeight = 160.0;
  static const double _shutterDiameter = 76.0;

  String _statusMessage = '구역을 가이드 안에 비춰 주세요';

  // ── 깜빡임 차단 카운터 ─────────────────────────────────────────────────────
  int _emptyFrameCount = 0;
  static const int _emptyResetThreshold = 3;

  // ── stability counter — toggling 방지 ────────────────────────────────────
  String? _stableCandidate;
  int _stableCount = 0;
  static const int _stabilityThreshold = 3;

  /// OCR 프레임 다운스케일 배율(줌 경로 전용). 2 = 가로·세로 1/2.
  /// 2×2 평균 샘플링이라 글자 경계가 보존된다.
  static const int _ocrDownscale = 2;

  /// 일반(비줌) 경로에서 ML Kit 에 보낼 **가운데 crop** 비율(업라이트 기준).
  /// 멀리서 작은 번호도 픽셀을 유지하도록 **풀해상도 그대로** 가운데만 잘라 보낸다
  /// (다운스케일 안 함). 주변(차·옆 표지판)이 빠져 가운데 번호가 자연히 선택된다.
  /// 가이드 박스(가로 ~0.59 · 세로 ~0.19)를 넉넉히 포함해 가까이서 꽉 채워도
  /// 글자가 잘리지 않는다.
  static const double _ocrCropFracW = 0.8;
  static const double _ocrCropFracH = 0.5;

  // ── 정규식 ─────────────────────────────────────────────────────────────────
  static final _alphaNumStrict =
      RegExp(r'^[A-Za-z][0-9]{1,3}$', caseSensitive: false);
  static final _zoneNumericStrict = RegExp(r'^[0-9]{2,3}$');

  /// STEP 1 — 층수 도려내기 정규식.
  ///   - "B1"~"B9" → 지하
  ///   - "1F"~"9F" → 지상
  static final _floorPattern =
      RegExp(r'\b(B[1-9]|[1-9]F)\b', caseSensitive: false);

  /// 한국 자동차 번호판 — 단일 줄 / 인접 두 줄 합침 모두 검사.
  ///   - 구형: "12가3456", "123가4567"
  ///   - 신형: "서울 12가 3456"
  static final _licensePlate =
      RegExp(r'(?:[가-힣]{2}\s?)?\d{2,3}\s?[가-힣]\s?\d{4}');

  static final _phoneNumber =
      RegExp(r'0[1-9][0-9]?[-\s.]?\d{3,4}[-\s.]?\d{4}');

  static final List<RegExp> _noiseFilters = [
    RegExp(
      r'\b(K[345789]|X[1-7]|Q[3578]|A[3-8]|G[789]0|GV[78]0|EV[69])\b',
      caseSensitive: false,
    ),
    RegExp(r'\b(10|20|30)\b|\b2\.[1-5][mM]?\b|높이|제한|서행'),
    RegExp(
      r'OUT|IN|EXIT|CCTV|SOS|EV|출구|입구|엘리베이터|타는곳|비상벨|소화전',
      caseSensitive: false,
    ),
    RegExp(r'장애인|경차|여성|임산부|전기차|전용|거주자'),
    RegExp(r'\b[1-9]F\b', caseSensitive: false),
    RegExp(r'\d+(동|호)\b|상가동|오피스텔'),
    RegExp(r'\bR[1-2][0-9]\b|\bZR[1-2][0-9]\b', caseSensitive: false),
    RegExp(r'\d+(분|시간|원|m|M|kW|kw)\b'),
    RegExp(r'쏘카|그린카|세차|발렛'),
    RegExp(r'\b[A-Z](동|구역|존)\b', caseSensitive: false),
  ];

  // ──────────────────────────────────────────────────────────────────────────
  //  Lifecycle
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _stopStreamSafely();
    _recognizer?.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isCapturing) return;
    // 초기화가 진행 중이면 lifecycle 변화에 반응하지 않는다.
    // 위젯 콜드 스타트 시 inactive↔resumed 토글이 _initCamera() 중복 호출을
    // 유발하던 race condition 차단.
    if (_initInProgress) return;
    if (state == AppLifecycleState.resumed && _permissionDenied) {
      if (!_awaitingSettingsReturn) return;
      _awaitingSettingsReturn = false;
      setState(() => _permissionDenied = false);
      _initCamera();
      return;
    }
    if (_permissionDenied) return;
    final c = _controller;
    if (state == AppLifecycleState.inactive) {
      // controller 가 null 이면 아직 init 끝나지 않은 상태 → 아무것도 안 함
      if (c == null || !c.value.isInitialized) return;
      _stopStreamSafely();
      // ── 빨간 화면(ErrorWidget) 깜빡임 방지 ─────────────────────────────
      // 폰 홈 버튼으로 백그라운드 전환 시 Android 가 task switcher 용 스크린샷
      // 1 프레임을 캡처한다. 만약 그 사이 controller 가 이미 dispose 되었는데
      // CameraPreview 위젯은 widget tree 에 남아 있으면 disposed controller
      // 접근 → ErrorWidget(빨간 화면) throw.
      //
      // 해결: setState 로 _controller=null 을 먼저 반영 → 다음 build 가
      // _buildPreview 의 검은색 폴백을 그리도록 함 → 그 frame 이 끝난 뒤
      // postFrameCallback 에서 native dispose. CameraPreview 가 widget tree
      // 에서 완전히 빠진 후에야 native 가 정리되므로 race 없음.
      setState(() {
        _controller = null;
        _isCameraReady = false;
        // 줌 상태도 함께 리셋 — 복귀 후 새 카메라 세션은 1.0x 로 시작하므로
        // 남겨두면 defaults 적용 전에 시작된 스트림이 풀화면 프레임을 옛
        // 배율로 크롭(_cropNv21Center)하고, 옛 배율 인디케이터도 남는다.
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _currentZoom = 1.0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        c.dispose();
      });
    } else if (state == AppLifecycleState.resumed) {
      // controller 가 살아있으면 stream 만 재개, 죽었으면 재초기화.
      if (c != null && c.value.isInitialized) {
        _startStream();
      } else {
        _initCamera();
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Camera init
  // ──────────────────────────────────────────────────────────────────────────

  /// `availableCameras()` 는 매 진입마다 결과가 같으므로 1회만 조회해 캐시.
  /// 재진입 시 채널 왕복 1회를 아껴 프리뷰 표시를 앞당긴다.
  static List<CameraDescription>? _cachedCameras;

  Future<void> _initCamera() async {
    // ── Reentrancy guard ──────────────────────────────────────────────────
    //   위젯 콜드 스타트 시 initState 의 _initCamera() #1 가 `await initialize()`
    //   중인데 lifecycle observer 가 resumed 이벤트를 받아 #2 를 호출하는
    //   race 차단. 둘 다 진행되면 native 카메라 락 경합 → 빨간 화면.
    if (_initInProgress) {
      debugPrint('[Camera] _initCamera() 재진입 무시 (이미 초기화 중)');
      return;
    }
    _initInProgress = true;
    try {
      final cameras = _cachedCameras ??= await availableCameras();
      if (cameras.isEmpty) {
        _setStatus('사용 가능한 카메라가 없습니다');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      // 구역번호는 영문+숫자(B2, A04, 30)뿐이라 기본(라틴) 모델로 충분하고
      // 한국어 모델보다 인식이 빠르다. 한글 안내판은 인식 자체를 안 해 노이즈도 감소.
      _recognizer ??= TextRecognizer();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // initialize 중에 lifecycle 이 끼어들어서 기존 controller 가 떨어져 나갔다면
      // 새로 만든 것도 stale 이 아니지만, 안전을 위해 기존 controller 가 살아있다면
      // 정리 후 교체.
      final old = _controller;
      if (old != null && old != controller) {
        try {
          await old.dispose();
        } catch (_) {}
      }
      // ── 프리뷰 즉시 표시 ──────────────────────────────────────────────────
      // 하드웨어 초기화가 끝난 시점에 바로 프리뷰를 띄운다. 줌·초점·노출·플래시
      // 설정은 각각 네이티브 채널 왕복이라 순서대로 await 하면 로딩바가 그만큼
      // 길어진다 → 프리뷰를 먼저 그리고 백그라운드로 이어서 적용한다.
      setState(() {
        _controller = controller;
        _isCameraReady = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _startStream());
      unawaited(_applyCameraDefaults(controller));
    } on CameraException catch (e) {
      if (e.code == 'CameraAccessDenied' ||
          e.code == 'CameraAccessDeniedWithoutPrompt' ||
          e.code == 'CameraAccessRestricted' ||
          e.code == 'permissionDenied') {
        if (mounted) setState(() => _permissionDenied = true);
      } else {
        _setStatus('카메라 오류: ${e.description}');
      }
    } catch (e) {
      _setStatus('카메라 초기화 실패: $e');
    } finally {
      _initInProgress = false;
    }
  }

  /// 프리뷰 표시 후 백그라운드로 적용하는 카메라 기본 설정.
  /// 프리뷰·스트림과 병행해도 안전한 호출들이며, 도중에 controller 가 교체·해제
  /// 되면 CameraException 이 나므로 각 단계를 개별 try/catch 로 감싼다.
  Future<void> _applyCameraDefaults(CameraController controller) async {
    bool stale() => !mounted || _controller != controller;
    // 플래시 기본값(auto)은 어두운 주차장에서 takePicture 마다 측광
    // (precapture) 시퀀스를 돌려 1~2초 셔터랙을 만든다. 라이브 OCR 은 이미
    // 무플래시 프리뷰 프레임으로 동작하므로 off 로 고정해 지연을 제거한다.
    try {
      if (stale()) return;
      await controller.setFlashMode(FlashMode.off);
    } catch (e) {
      debugPrint('[Camera] 플래시 off 설정 실패: $e');
    }
    // 가운데(번호가 오는 곳)에 초점·노출 고정 — 멀리서 차+기둥을 함께 잡을 때
    // 카메라가 가까운 차/배경에 초점을 빼앗겨 가운데 기둥 번호가 흐려져 인식이
    // 안 되던 문제 방지. 사용자가 화면을 탭하면 그 지점으로 다시 잡는다(_onTapFocus).
    try {
      if (stale()) return;
      await controller.setFocusMode(FocusMode.auto);
      await controller.setFocusPoint(const Offset(0.5, 0.5));
      await controller.setExposureMode(ExposureMode.auto);
      await controller.setExposurePoint(const Offset(0.5, 0.5));
    } catch (e) {
      debugPrint('[Camera] 중앙 초점 설정 실패: $e');
    }
    // 줌 범위 로드 — 순정 카메라처럼 기기 전체 범위 사용: minZoom < 1.0 이면
    // 초광각(0.6x 등)까지 축소 허용, 시작 배율만 순정과 동일하게 1.0x.
    // 두 getter 는 독립 읽기 채널 왕복이라 병렬 조회.
    try {
      if (stale()) return;
      final levels = await Future.wait(
          [controller.getMinZoomLevel(), controller.getMaxZoomLevel()]);
      double minZ = levels[0];
      double maxZ = levels[1];
      // 플랫폼이 역전된 범위(max < min)를 보고하면 줌 미지원으로 취급.
      // num.clamp 는 lower > upper 면 ArgumentError 라 방어 필수.
      if (maxZ < minZ) {
        minZ = 1.0;
        maxZ = 1.0;
      }
      final double startZ = minZ >= 1.0 ? minZ : (maxZ >= 1.0 ? 1.0 : maxZ);
      if (stale()) return;
      // 이 필드들은 build(줌 인디케이터·크롭 배율)가 읽으므로 setState 로 반영.
      // stale 재확인 후 한 번에 대입 — 교체된 컨트롤러의 늦은 응답이 살아있는
      // 컨트롤러의 값을 덮어쓰거나, min/max 가 찢어진 상태로 그려지는 것 방지.
      setState(() {
        _minZoom = minZ;
        _maxZoom = maxZ;
        _currentZoom = startZ;
        _baseScaleZoom = startZ;
      });
      // 시작 배율 적용 실패(세션 바인딩 중 등)는 범위와 무관 — 범위는 유지.
      try {
        await controller.setZoomLevel(startZ);
      } catch (e) {
        debugPrint('[Camera] 초기 setZoomLevel 실패: $e');
      }
    } catch (e) {
      debugPrint('[Camera] zoom 범위 조회 실패: $e');
      if (stale()) return;
      setState(() {
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _currentZoom = 1.0;
      });
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Stream control
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _startStream() async {
    if (_isCapturing || _popped) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isStreamingImages) return;
    try {
      await c.startImageStream(_onFrame);
    } catch (e) {
      debugPrint('[Camera] stream 시작 실패: $e');
    }
  }

  Future<void> _stopStreamSafely() async {
    final c = _controller;
    if (c == null) return;
    if (!c.value.isStreamingImages) return;
    try {
      await c.stopImageStream();
    } catch (_) {}
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Frame analysis
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _onFrame(CameraImage image) async {
    if (_isCapturing || _isProcessing || _popped) return;
    final controller = _controller;
    final recognizer = _recognizer;
    if (controller == null || recognizer == null) return;
    if (!controller.value.isStreamingImages) return;

    _isProcessing = true;
    try {
      final input = _buildInputImage(
        image,
        controller.description.sensorOrientation,
      );
      if (input == null) return;
      final recognized = await recognizer.processImage(input);
      if (!mounted || _isCapturing || _popped) return;

      // 좌표 변환 파라미터(_lastUprightW/H, _ocrOffX/Y, _ocrCroppedToGuide)는
      // _buildInputImage 가 이번 프레임의 crop/downscale 에 맞춰 이미 세팅했다.
      final winner = _extractParse(recognized);
      if (winner == null) {
        _emptyFrameCount++;
        if (_emptyFrameCount >= _emptyResetThreshold && _arBox != null) {
          setState(() {
            _arBox = null;
            _lastMatchedZone = null;
            _lastMatchedFloorType = null;
            _lastMatchedFloorNum = null;
            _stableCandidate = null;
            _stableCount = 0;
            _statusMessage = '구역을 가이드 안에 비춰 주세요';
          });
        }
        return;
      }
      _emptyFrameCount = 0;

      // ── stability counter (zone 기준, floor 는 같이 업데이트) ──────────
      final String newZone = winner.zone;
      final bool shouldUpdate;
      if (_lastMatchedZone == null) {
        _stableCandidate = newZone;
        _stableCount = _stabilityThreshold;
        shouldUpdate = true;
      } else if (newZone == _lastMatchedZone) {
        _stableCandidate = newZone;
        _stableCount = _stabilityThreshold;
        shouldUpdate = true;
      } else if (newZone != _stableCandidate) {
        _stableCandidate = newZone;
        _stableCount = 1;
        shouldUpdate = false;
      } else {
        _stableCount++;
        shouldUpdate = _stableCount >= _stabilityThreshold;
      }

      if (!shouldUpdate) return;

      // ── AR 박스 lock — 같은 zone 동안 위치 고정 ──────────────────────
      // ML Kit 의 매 프레임 boundingBox jitter + 손떨림이 박스에 그대로
      // 반영되던 회귀 해결. 같은 zone 매칭이 들어와도 박스 위치는
      // _arBox 의 첫 잡힌 위치를 유지. zone 자체가 바뀐 첫 프레임에만
      // 새 박스로 즉시 점프. floor 라벨은 늦게 잡힐 수 있으니 별도 갱신.
      final bool isSameZone = newZone == _lastMatchedZone;
      final bool floorChanged =
          winner.floorType != _lastMatchedFloorType ||
              winner.floorNum != _lastMatchedFloorNum;
      // 모든 상태가 동일하면 setState 호출 자체를 생략 — 매 프레임 rebuild 차단.
      if (isSameZone && !floorChanged && _arBox != null) return;

      setState(() {
        if (!isSameZone || _arBox == null) {
          // 새 zone 또는 첫 매칭 → 박스 새로 잡음.
          _arBox = _transformBox(winner.box);
        }
        // (같은 zone 이면 _arBox 는 그대로 유지.)
        _lastMatchedZone = newZone;
        _lastMatchedFloorType = winner.floorType;
        _lastMatchedFloorNum = winner.floorNum;
        if (winner.floorType != null && winner.floorNum != null) {
          _statusMessage =
              '인식: ${winner.floorType} ${winner.floorNum}층 / $newZone';
        } else {
          _statusMessage = '인식: $newZone';
        }
      });
    } catch (e) {
      debugPrint('[Camera] frame 예외: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// v14 — 가이드 박스 영역 기반 OCR 필터.
  ///
  /// ## 알고리즘
  ///   1차: 모든 blocks 의 lines 를 모은 후, **boundingBox 가 가이드 박스(ML Kit
  ///        input 좌표) 와 50% 이상 교차하는 lines 만** 채택 → _parseLines.
  ///   2차 fallback: 가이드 박스 안에 매칭 없을 때만 전체 lines 로 재시도
  ///        (안전망 — 가이드 박스 좌표 계산 실패 / edge case).
  ///
  /// ## 도입 배경 (v13 결함 해결)
  ///   v13 의 `largest block` 알고리즘은 광고/주변 안내문이 화면에서 가장 큰
  ///   영역을 차지하면 그쪽을 채택해 기둥 번호를 놓치는 결함이 있었다. 가이드
  ///   박스의 의미 ("여기에 글자를 비춰주세요") 와 OCR 동작을 일치시켜
  ///   사용자가 가이드에 글자를 맞추면 옆 글자 / 광고 / 천장 안내가 자동 제외.
  _ParseResult? _extractParse(RecognizedText recognized) {
    debugPrint(
      '[Camera] OCR raw="${recognized.text.replaceAll("\n", " ¶ ")}"',
    );

    // 모든 blocks 의 lines 를 일렬로 모은다 (block 단위 largest 폐기).
    final allLines = <TextLine>[];
    for (final block in recognized.blocks) {
      allLines.addAll(block.lines);
    }
    if (allLines.isEmpty) {
      debugPrint('[Camera] 매칭 없음 (라인 0개)');
      return null;
    }

    // ── 1차: 가이드 박스 영역 내 lines 만 필터 ──────────────────────────
    // 이미 가이드 영역으로 crop 해 보낸 경우(_ocrCroppedToGuide)는 들어온 라인이
    // 곧 가이드 내 라인이므로 교차 필터를 건너뛰고 전체 라인으로 바로 파싱한다.
    final guideInputRect =
        _ocrCroppedToGuide ? null : _guideBoxInInputCoords();
    if (guideInputRect != null) {
      final inGuide = allLines.where((line) {
        final b = line.boundingBox;
        final inter = b.intersect(guideInputRect);
        if (inter.width <= 0 || inter.height <= 0) return false;
        final lineArea = b.width * b.height;
        if (lineArea <= 0) return false;
        // 라인 면적의 50% 이상이 가이드 박스 안에 들어와야 통과.
        return (inter.width * inter.height) >= lineArea * 0.5;
      }).toList();
      if (inGuide.isNotEmpty) {
        final r = _parseLines(inGuide);
        if (r != null && r.zone.isNotEmpty) {
          debugPrint(
            '[Camera] 1차 매칭 (가이드 박스 내 ${inGuide.length}/${allLines.length} 라인): '
            'floor=${r.floorType}/${r.floorNum}, zone=${r.zone}',
          );
          return r;
        }
      }
    }

    // ── 2차 fallback: 전체 lines (가이드 박스 좌표 계산 실패 / edge case) ─
    final r2 = _parseLines(allLines);
    if (r2 != null && r2.zone.isNotEmpty) {
      debugPrint(
        '[Camera] 2차 매칭 (가이드 무시 전체 ${allLines.length} 라인): '
        'floor=${r2.floorType}/${r2.floorNum}, zone=${r2.zone}',
      );
      return r2;
    }

    debugPrint('[Camera] 매칭 없음 (1차/2차 모두 실패)');
    return null;
  }

  /// 가이드 박스를 ML Kit InputImage 좌표계로 역변환한 Rect.
  ///
  /// [_transformBox] 의 역연산. 화면 가이드 박스 (중앙 280×160) → ML Kit 가
  /// 보는 좌표계 (회전 후 cropW × cropH, 줌 인 상태면 cropped 영역) 로 매핑.
  Rect? _guideBoxInInputCoords() {
    if (_lastUprightW <= 0 || _lastUprightH <= 0) return null;
    final box = _previewContainerKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final containerSize = box.size;

    // 가이드 박스의 화면 좌표 (Stack 의 Center 위치).
    final guideScreen = Rect.fromCenter(
      center: Offset(containerSize.width / 2, containerSize.height / 2),
      width: _guideBoxWidth,
      height: _guideBoxHeight,
    );

    // _transformBox 와 동일한 BoxFit.cover scale 계산.
    final double scaleX = containerSize.width / _lastUprightW;
    final double scaleY = containerSize.height / _lastUprightH;
    final double scale = scaleX > scaleY ? scaleX : scaleY;
    if (scale <= 0) return null;
    final double offsetX = (containerSize.width - _lastUprightW * scale) / 2.0;
    final double offsetY = (containerSize.height - _lastUprightH * scale) / 2.0;

    // 역변환: input.x = (screen.x - offsetX) / scale.
    return Rect.fromLTRB(
      (guideScreen.left - offsetX) / scale,
      (guideScreen.top - offsetY) / scale,
      (guideScreen.right - offsetX) / scale,
      (guideScreen.bottom - offsetY) / scale,
    );
  }

  /// lines → zone 파싱.
  ///  1차: 전체를 읽기순으로 결합해 zone 검사 (단일 번호/분할 자릿수/번호+층 등
  ///       기존이 처리하던 모든 케이스 — **동작 동일, 회귀 없음**).
  ///  2차: 1차 실패(여러 글자 섞여 결합이 패턴에 안 맞음) 시에만, 근접 라인끼리
  ///       클러스터로 묶어 각각 검사하고 **화면 중심에 가장 가까운** zone 을 고른다.
  ///       (멀리서 차+기둥을 함께 잡아 다른 번호까지 들어올 때 가운데 번호 우선.)
  _ParseResult? _parseLines(List<TextLine> lines) {
    // ── 노이즈 필터 ──────────────────────────────────────────────────────
    final cleanLines = <TextLine>[];
    for (final line in lines) {
      final t = line.text.trim();
      if (t.isEmpty) continue;
      if (_licensePlate.hasMatch(t)) continue;
      if (_phoneNumber.hasMatch(t)) continue;
      var noise = false;
      for (final f in _noiseFilters) {
        if (f.hasMatch(t)) {
          noise = true;
          break;
        }
      }
      if (noise) continue;
      cleanLines.add(line);
    }
    if (cleanLines.isEmpty) return null;

    // 층수는 전체 시야에서 한 번만 추출 — 어느 zone 이 뽑히든 공통 적용.
    String? floorType;
    String? floorNum;
    final fm = _floorPattern
        .firstMatch(cleanLines.map((l) => l.text.trim()).join(' '));
    if (fm != null) {
      final matched = fm.group(0)!.toUpperCase(); // "B2" or "2F"
      if (matched.startsWith('B')) {
        floorType = '지하';
        floorNum = matched.substring(1);
      } else {
        floorType = '지상';
        floorNum = matched.substring(0, matched.length - 1);
      }
    }

    // ── 1차: 전체 결합 (기존 동작 — 회귀 0) ──────────────────────────────
    // 읽기순으로 정렬 후 결합. ML Kit 순서는 좌→우 보장이 안 돼 "3" "0" 이
    // "0 3"→"03" 처럼 뒤집히던 사고를 방지(boundingBox 위치로 재정렬).
    final byReading = [...cleanLines]..sort(_readingOrderCompare);
    final zoneAll = _matchZone(byReading.map((l) => l.text.trim()).join(' '));
    if (zoneAll != null) {
      return _ParseResult(
        floorType: floorType,
        floorNum: floorNum,
        zone: zoneAll,
        box: _unionBox(byReading),
      );
    }

    // ── 2차: 1차 실패 → 클러스터별 검사 후 중심 최근접 zone 선택 ──────────
    final clusters = _clusterLines(cleanLines);
    if (clusters.length <= 1) return null; // 1개면 1차와 동일 → 이미 실패
    _ParseResult? best;
    double bestDist = double.infinity;
    for (final cluster in clusters) {
      final sorted = [...cluster]..sort(_readingOrderCompare);
      final zone = _matchZone(sorted.map((l) => l.text.trim()).join(' '));
      if (zone == null) continue;
      final box = _unionBox(sorted);
      final d = (box.center - _ocrCenter).distanceSquared;
      if (d < bestDist) {
        bestDist = d;
        best = _ParseResult(
          floorType: floorType,
          floorNum: floorNum,
          zone: zone,
          box: box,
        );
      }
    }
    return best;
  }

  /// floor 제거 → 공백 압착 → strict zone 패턴 검사. 매치 없으면 null.
  String? _matchZone(String text) {
    final compact =
        text.replaceAll(_floorPattern, '').replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return null;
    if (_alphaNumStrict.hasMatch(compact)) return compact.toUpperCase();
    if (_zoneNumericStrict.hasMatch(compact)) return compact;
    return null;
  }

  /// 읽는 순서 비교자(같은 줄대면 왼→오른, 줄이 다르면 위→아래).
  static int _readingOrderCompare(TextLine a, TextLine b) {
    final ab = a.boundingBox;
    final bb = b.boundingBox;
    final rowBand = (ab.height < bb.height ? ab.height : bb.height) * 0.5;
    if ((ab.center.dy - bb.center.dy).abs() <= rowBand) {
      return ab.left.compareTo(bb.left);
    }
    return ab.center.dy.compareTo(bb.center.dy);
  }

  static Rect _unionBox(List<TextLine> lines) {
    Rect box = lines.first.boundingBox;
    for (int i = 1; i < lines.length; i++) {
      box = box.expandToInclude(lines[i].boundingBox);
    }
    return box;
  }

  /// 근접 라인끼리 묶는다(세로로 겹치는 같은 줄대 + 가로 간격이 글자 높이의
  /// ~1.5배 이내). "A" "30" 처럼 한 라벨이 떨어져 잡혀도 한 클러스터가 되도록
  /// 간격을 넉넉히 둔다(과합치기는 1차와 동일해져 무해, 과분리만 피하면 됨).
  static List<List<TextLine>> _clusterLines(List<TextLine> lines) {
    final clusters = <List<TextLine>>[];
    for (final line in lines) {
      final lb = line.boundingBox;
      bool placed = false;
      for (final cluster in clusters) {
        for (final m in cluster) {
          final mb = m.boundingBox;
          final vOverlap = lb.bottom > mb.top && mb.bottom > lb.top;
          final gapTol = (lb.height < mb.height ? lb.height : mb.height) * 1.5;
          final double hGap = lb.left > mb.right
              ? lb.left - mb.right
              : mb.left > lb.right
                  ? mb.left - lb.right
                  : 0.0;
          if (vOverlap && hGap <= gapTol) {
            cluster.add(line);
            placed = true;
            break;
          }
        }
        if (placed) break;
      }
      if (!placed) clusters.add([line]);
    }
    return clusters;
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  CameraImage → InputImage (YUV420→NV21)
  // ──────────────────────────────────────────────────────────────────────────

  InputImage? _buildInputImage(CameraImage image, int sensorOrientation) {
    final InputImageRotation rotation = _degToRotation(sensorOrientation);
    final bool swap = sensorOrientation == 90 || sensorOrientation == 270;
    final int srcW = image.width;
    final int srcH = image.height;
    // 회전 후(업라이트) 풀 프레임 크기 — 프리뷰가 cover 로 보여주는 좌표계.
    final double uwFull = (swap ? srcH : srcW).toDouble();
    final double uhFull = (swap ? srcW : srcH).toDouble();

    Uint8List bytes;
    final InputImageFormat format;
    int bytesPerRow;
    int outW = srcW;
    int outH = srcH;

    // 좌표 변환 파라미터 기본값(최적화 없음): 풀 프레임이 프리뷰에 cover, 오프셋 0.
    double covW = uwFull;
    double covH = uhFull;
    double offX = 0;
    double offY = 0;
    bool croppedToGuide = false;

    if (Platform.isAndroid) {
      final conv = _yuv420ToNv21(image);
      if (conv == null) return null;
      bytes = conv;

      if (_currentZoom > 1.05) {
        // ── 줌 경로 ──────────────────────────────────────────────────────
        // 하드웨어 줌과 같은 중앙만 crop 후 다운스케일. 프리뷰가 crop 영역을
        // 꽉 채우므로 cov = (다운스케일된) 영상 크기, 오프셋 0.
        final cropped = _cropNv21Center(conv, srcW, srcH, _currentZoom);
        if (cropped != null) {
          bytes = cropped.bytes;
          outW = cropped.width;
          outH = cropped.height;
        }
        if (_ocrDownscale > 1) {
          final ds = _downscaleNv21Gray(bytes, outW, outH, _ocrDownscale);
          if (ds != null) {
            bytes = ds.bytes;
            outW = ds.width;
            outH = ds.height;
          }
        }
        covW = (swap ? outH : outW).toDouble();
        covH = (swap ? outW : outH).toDouble();
      } else {
        // ── 일반 경로: 가운데 영역만 **풀해상도** crop ───────────────────
        // 멀리서 작은 번호도 픽셀을 유지(다운스케일 안 함)하고, 주변이 빠져
        // 가운데 번호가 선택된다. 프리뷰는 풀 프레임을 보여주므로 cov = 풀
        // 업라이트, 오프셋 = crop 좌상단(업라이트). 가이드보다 넉넉해 안 잘림.
        final int cropSW =
            (swap ? srcW * _ocrCropFracH : srcW * _ocrCropFracW).round() & ~1;
        final int cropSH =
            (swap ? srcH * _ocrCropFracW : srcH * _ocrCropFracH).round() & ~1;
        if (cropSW >= 32 && cropSH >= 32 && cropSW <= srcW && cropSH <= srcH) {
          final int cropX = ((srcW - cropSW) ~/ 2) & ~1;
          final int cropY = ((srcH - cropSH) ~/ 2) & ~1;
          final cropped =
              _cropNv21Rect(conv, srcW, srcH, cropX, cropY, cropSW, cropSH);
          if (cropped != null) {
            bytes = cropped.bytes;
            outW = cropped.width;
            outH = cropped.height;
            offX = uwFull * (1 - _ocrCropFracW) / 2;
            offY = uhFull * (1 - _ocrCropFracH) / 2;
            croppedToGuide = true;
          }
        }
        // crop 실패 시 풀 프레임 폴백 — cov = 풀 업라이트(기본값), 오프셋 0.
      }

      format = InputImageFormat.nv21;
      bytesPerRow = outW;
    } else {
      if (image.planes.isEmpty) return null;
      bytes = image.planes.first.bytes;
      format = InputImageFormat.bgra8888;
      bytesPerRow = image.planes.first.bytesPerRow;
    }

    // 좌표 변환 단일 출처 — _transformBox / _guideBoxInInputCoords 가 사용.
    _lastUprightW = covW;
    _lastUprightH = covH;
    _ocrOffX = offX;
    _ocrOffY = offY;
    _ocrCroppedToGuide = croppedToGuide;
    // boundingBox 좌표계(= ML Kit 입력의 업라이트) 중심. 2차 파싱의 거리 기준.
    _ocrCenter = Offset(
      (swap ? outH : outW) / 2.0,
      (swap ? outW : outH) / 2.0,
    );

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(outW.toDouble(), outH.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: bytesPerRow,
      ),
    );
  }

  /// NV21 을 짝수 정렬 사각형으로 crop 한다(Y + interleaved VU). 풀해상도 유지.
  /// [cropX]/[cropY]/[cropW]/[cropH] 는 모두 짝수여야 한다(YUV 4:2:0 정렬).
  static _CropResult? _cropNv21Rect(
    Uint8List nv21,
    int srcW,
    int srcH,
    int cropX,
    int cropY,
    int cropW,
    int cropH,
  ) {
    if (cropW < 32 || cropH < 32) return null;
    if (cropX < 0 || cropY < 0 || cropX + cropW > srcW || cropY + cropH > srcH) {
      return null;
    }
    final int ySize = cropW * cropH;
    final int vuSize = cropW * cropH ~/ 2;
    final out = Uint8List(ySize + vuSize);

    int dst = 0;
    for (int row = 0; row < cropH; row++) {
      final int srcStart = (cropY + row) * srcW + cropX;
      out.setRange(dst, dst + cropW, nv21, srcStart);
      dst += cropW;
    }
    final int vuSrcOffset = srcW * srcH;
    for (int row = 0; row < cropH ~/ 2; row++) {
      final int srcStart = vuSrcOffset + (cropY ~/ 2 + row) * srcW + cropX;
      out.setRange(dst, dst + cropW, nv21, srcStart);
      dst += cropW;
    }
    return _CropResult(bytes: out, width: cropW, height: cropH);
  }

  /// NV21 을 [factor] 배(정수) 축소한 **회색조** NV21 을 만든다.
  ///
  /// 텍스트 인식은 휘도(Y)만으로 충분하므로 Y 만 축소하고 VU(채도) 평면은
  /// 중립 회색(128)으로 채워 유효한 NV21 을 유지한다. factor=2 면 픽셀 1/4 →
  /// ML Kit 약 4배 빠름. 너무 작아지면 null(원본 폴백).
  ///
  /// 샘플링은 **box 평균**(factor×factor 블록 평균)이다. 단순 최근접 샘플링은
  /// 계단현상(앨리어싱)으로 숫자가 뭉개져 3↔8, 0↔8 오인식·미검출을 유발했는데,
  /// 평균은 글자 경계를 매끈하게 보존해 같은 속도로 인식 정확도를 끌어올린다.
  static _CropResult? _downscaleNv21Gray(
    Uint8List nv21,
    int srcW,
    int srcH,
    int factor,
  ) {
    if (factor <= 1) return null;
    final int newW = (srcW ~/ factor) & ~1; // 짝수 정렬 (YUV 4:2:0)
    final int newH = (srcH ~/ factor) & ~1;
    if (newW < 32 || newH < 32) return null;
    final int ySize = newW * newH;
    final int vuSize = newW * newH ~/ 2;
    final out = Uint8List(ySize + vuSize);
    final int area = factor * factor;
    final int half = area ~/ 2; // 반올림용
    int dst = 0;
    for (int row = 0; row < newH; row++) {
      final int srcRow0 = (row * factor) * srcW;
      for (int col = 0; col < newW; col++) {
        final int srcCol0 = col * factor;
        int sum = 0;
        for (int dy = 0; dy < factor; dy++) {
          final int base = srcRow0 + dy * srcW + srcCol0;
          for (int dx = 0; dx < factor; dx++) {
            sum += nv21[base + dx];
          }
        }
        out[dst++] = (sum + half) ~/ area; // 블록 평균(반올림)
      }
    }
    out.fillRange(ySize, ySize + vuSize, 128); // 채도 중립(회색)
    return _CropResult(bytes: out, width: newW, height: newH);
  }

  /// NV21 영상을 zoom 배율만큼 중앙 crop.
  ///
  /// NV21 layout: Y plane (W×H bytes) + VU interleaved plane (W×H/2 bytes,
  /// 2×2 subsampled). crop 좌표/크기는 YUV 4:2:0 subsampling 정렬을 위해 모두
  /// 짝수로 정렬한다.
  static _CropResult? _cropNv21Center(
    Uint8List nv21,
    int srcW,
    int srcH,
    double zoom,
  ) {
    if (zoom <= 1.0) return null;
    int cropW = (srcW / zoom).round() & ~1; // 짝수 정렬 (마지막 비트 마스킹)
    int cropH = (srcH / zoom).round() & ~1;
    if (cropW < 32 || cropH < 32) return null; // 너무 작으면 폴백
    int cropX = ((srcW - cropW) ~/ 2) & ~1;
    int cropY = ((srcH - cropH) ~/ 2) & ~1;

    final ySize = cropW * cropH;
    final vuSize = cropW * cropH ~/ 2;
    final out = Uint8List(ySize + vuSize);

    // Y plane crop
    int dst = 0;
    for (int row = 0; row < cropH; row++) {
      final srcStart = (cropY + row) * srcW + cropX;
      out.setRange(dst, dst + cropW, nv21, srcStart);
      dst += cropW;
    }

    // VU plane crop — interleaved VU, 2×2 subsampled. cropX/Y 짝수 정렬이
    // 보장되었으므로 정확히 cropY/2 행, cropX 열에서 시작.
    final vuSrcOffset = srcW * srcH;
    for (int row = 0; row < cropH ~/ 2; row++) {
      final srcStart = vuSrcOffset + (cropY ~/ 2 + row) * srcW + cropX;
      out.setRange(dst, dst + cropW, nv21, srcStart);
      dst += cropW;
    }

    return _CropResult(bytes: out, width: cropW, height: cropH);
  }

  static Uint8List? _yuv420ToNv21(CameraImage image) {
    if (image.planes.length < 3) return null;
    final int width = image.width;
    final int height = image.height;
    if (width <= 0 || height <= 0) return null;
    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];
    final int ySize = width * height;
    final int uvSize = (width ~/ 2) * (height ~/ 2) * 2;
    final Uint8List nv21 = Uint8List(ySize + uvSize);
    final Uint8List yBytes = yPlane.bytes;
    final int yRowStride = yPlane.bytesPerRow;
    final int yPixelStride = yPlane.bytesPerPixel ?? 1;
    int dst = 0;
    if (yPixelStride == 1 && yRowStride == width) {
      nv21.setRange(0, ySize, yBytes);
      dst = ySize;
    } else {
      for (int row = 0; row < height; row++) {
        final int srcRow = row * yRowStride;
        if (yPixelStride == 1) {
          nv21.setRange(dst, dst + width, yBytes, srcRow);
          dst += width;
        } else {
          for (int col = 0; col < width; col++) {
            nv21[dst++] = yBytes[srcRow + col * yPixelStride];
          }
        }
      }
    }
    final Uint8List uBytes = uPlane.bytes;
    final Uint8List vBytes = vPlane.bytes;
    final int uRowStride = uPlane.bytesPerRow;
    final int vRowStride = vPlane.bytesPerRow;
    final int uPixelStride = uPlane.bytesPerPixel ?? 2;
    final int vPixelStride = vPlane.bytesPerPixel ?? 2;
    final int uvHeight = height ~/ 2;
    final int uvWidth = width ~/ 2;
    for (int row = 0; row < uvHeight; row++) {
      final int uRow = row * uRowStride;
      final int vRow = row * vRowStride;
      for (int col = 0; col < uvWidth; col++) {
        final int uIdx = uRow + col * uPixelStride;
        final int vIdx = vRow + col * vPixelStride;
        final int vByte = vIdx < vBytes.length ? vBytes[vIdx] : 0;
        final int uByte = uIdx < uBytes.length ? uBytes[uIdx] : 0;
        nv21[dst++] = vByte;
        nv21[dst++] = uByte;
      }
    }
    return nv21;
  }

  static InputImageRotation _degToRotation(int deg) {
    switch (deg) {
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

  Rect? _transformBox(Rect raw) {
    if (_lastUprightW <= 0 || _lastUprightH <= 0) return null;
    final box = _previewContainerKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final containerSize = box.size;
    final double scaleX = containerSize.width / _lastUprightW;
    final double scaleY = containerSize.height / _lastUprightH;
    // _buildPreview() 가 FittedBox(BoxFit.cover) 를 쓰므로 좌표 변환도 cover.
    // cover = max(scaleX, scaleY), 영상이 화면보다 크게 그려져 중앙 crop.
    // offset 은 음수가 되어 잘린 부분만큼 마이너스 좌표로 빠진다 (자연스러움).
    final double scale = scaleX > scaleY ? scaleX : scaleY;
    final double offsetX = (containerSize.width - _lastUprightW * scale) / 2.0;
    final double offsetY = (containerSize.height - _lastUprightH * scale) / 2.0;
    // raw(boundingBox)는 OCR 입력(crop) 좌표 → _ocrOff 로 풀 프레임(cov) 좌표로
    // 옮긴 뒤 cover scale 적용. crop 안 한 경로는 _ocrOff=0 이라 그대로다.
    return Rect.fromLTRB(
      (raw.left + _ocrOffX) * scale + offsetX,
      (raw.top + _ocrOffY) * scale + offsetY,
      (raw.right + _ocrOffX) * scale + offsetX,
      (raw.bottom + _ocrOffY) * scale + offsetY,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Shutter — takePicture + pop
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _onShutter() async {
    if (_isCapturing || _popped) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    _isCapturing = true;
    if (mounted) setState(() => _statusMessage = '사진 저장 중...');
    // 셔터를 막지 않도록 햅틱은 대기하지 않는다.
    unawaited(HapticFeedback.mediumImpact());

    final sw = Stopwatch()..start();
    String? tempPath;
    String? savedPath;
    try {
      // 스트림은 멈추지 않는다 — stopImageStream 은 CameraX use case unbind →
      // 세션 재구성을 유발해 그 자체로 수백 ms 셔터랙을 만들었다(+ 기존 300ms
      // 고정 쿨다운, 최대 300ms OCR 완료 대기까지 ~1초). 새 프레임 OCR 은
      // _onFrame 첫 줄의 _isCapturing 가드가 차단하고, 진행 중이던 프레임은
      // 캡처와 버퍼를 공유하지 않으므로 그대로 끝나게 두면 된다.
      final XFile xFile = await controller.takePicture();
      tempPath = xFile.path;
      savedPath = await _savePhoto(tempPath);
      tempPath = null;

      if (!mounted) return;
      _popped = true;
      final result = {
        'zone': _lastMatchedZone ?? '',
        'floorType': _lastMatchedFloorType ?? '',
        'floorNum': _lastMatchedFloorNum ?? '',
        'imagePath': savedPath,
      };
      debugPrint('[Camera] shutter pop (${sw.elapsedMilliseconds}ms) → $result');
      Navigator.of(context).pop(result);
    } catch (e) {
      debugPrint('[Camera] 셔터 예외: $e');
      if (savedPath != null && mounted && !_popped) {
        _popped = true;
        Navigator.of(context).pop({
          'zone': _lastMatchedZone ?? '',
          'floorType': _lastMatchedFloorType ?? '',
          'floorNum': _lastMatchedFloorNum ?? '',
          'imagePath': savedPath,
        });
        return;
      }
      if (mounted) {
        setState(() => _statusMessage = '촬영 오류 — 다시 시도해 주세요');
      }
    } finally {
      _isCapturing = false;
      if (mounted && !_popped) {
        _startStream();
        if (mounted) {
          setState(() {
            if (_statusMessage == '사진 저장 중...') {
              _statusMessage = '구역을 가이드 안에 비춰 주세요';
            }
          });
        }
      }
      if (tempPath != null) {
        try {
          await File(tempPath).delete();
        } catch (_) {}
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Helpers
  // ──────────────────────────────────────────────────────────────────────────

  Future<String> _savePhoto(String tempPath) async {
    final dir = await getApplicationDocumentsDirectory();
    final fileName = 'parking_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = '${dir.path}/$fileName';
    // PIPA / 위치정보법 컴플라이언스: 사진에 박힌 EXIF GPS·카메라 모델·타임스탬프
    // 등을 제거해 카카오톡 공유 시 위치 메타데이터 노출 차단.
    // 디코드 실패 시(드물게) 원본 단순 복사로 폴백 — 저장 자체는 보장.
    await compute(_stripExifAndSave, _CopyParams(tempPath, destPath));
    // takePicture() 가 만든 캐시 원본을 삭제한다. 이 정리를 빠뜨리면 캡처본(temp)
    // 과 최종본(dest) 이 둘 다 남아 "사진이 2장씩 저장된다" 는 증상이 발생한다.
    try {
      await File(tempPath).delete();
    } catch (_) {}
    return destPath;
  }

  void _setStatus(String msg) {
    if (mounted) setState(() => _statusMessage = msg);
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Zoom — 핀치 제스처 + setZoomLevel
  // ──────────────────────────────────────────────────────────────────────────

  /// 갤럭시 순정 카메라식 배율 프리셋: [초광각(있으면), 1x, 망원(범위가 되면 3x
  /// 아니면 2x)]. 실제 기기 줌 범위로부터 계산한다.
  List<double> get _zoomPresets {
    final presets = <double>[];
    if (_minZoom < 0.95) presets.add(_minZoom);
    presets.add(1.0);
    if (_maxZoom >= 2.9) {
      presets.add(3.0);
    } else if (_maxZoom >= 1.9) {
      presets.add(2.0);
    }
    return presets;
  }

  Future<void> _setZoomPreset(double z) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final target = z.clamp(_minZoom, _maxZoom).toDouble();
    HapticFeedback.selectionClick();
    try {
      await c.setZoomLevel(target);
      if (!mounted) return;
      setState(() {
        _currentZoom = target;
        _baseScaleZoom = target;
      });
    } catch (e) {
      debugPrint('[Camera] 줌 프리셋 적용 실패: $e');
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    // 현재 줌을 스냅샷 — 이후 onScaleUpdate 에서 누적이 아니라 base × scale.
    _baseScaleZoom = _currentZoom;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails d) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_maxZoom <= _minZoom) return; // 줌 미지원 기기(또는 범위 로드 전)
    // base × scale 후 기기 전체 범위 [minZoom..maxZoom] 클램프 — 순정 카메라처럼
    // minZoom < 1.0 인 기기에선 초광각(0.6x 등)까지 축소 가능.
    final target =
        (_baseScaleZoom * d.scale).clamp(_minZoom, _maxZoom).toDouble();
    if ((target - _currentZoom).abs() < 0.01) return; // 미세 변동 무시
    try {
      await c.setZoomLevel(target);
      if (!mounted) return;
      setState(() => _currentZoom = target);
    } catch (e) {
      debugPrint('[Camera] setZoomLevel 실패: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Tap to focus — 갤럭시 기본 카메라처럼 탭한 지점에 초점/노출
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _onTapFocus(TapUpDetails d) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _isCapturing || _popped) return;
    final renderBox =
        _previewContainerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final size = renderBox.size;
    if (size.width <= 0 || size.height <= 0) return;

    // 탭 지점을 프리뷰 정규화 좌표 [0,1] 로 변환해 초점/노출 지점 지정.
    final double nx = (d.localPosition.dx / size.width).clamp(0.0, 1.0);
    final double ny = (d.localPosition.dy / size.height).clamp(0.0, 1.0);
    final point = Offset(nx, ny);

    try {
      // auto 모드로 전환해 지정 지점에 즉시 재초점(고정 모드면 한 번만 잡고 멈춤).
      await c.setFocusMode(FocusMode.auto);
      await c.setFocusPoint(point);
      await c.setExposurePoint(point);
    } catch (e) {
      debugPrint('[Camera] 탭 포커스 실패: $e');
    }

    // 포커스 링 표시 후 1초 뒤 자동 숨김.
    if (!mounted) return;
    setState(() => _focusIndicator = d.localPosition);
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) setState(() => _focusIndicator = null);
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) return _buildPermissionDeniedScreen();
    return Scaffold(
      backgroundColor: Colors.black,
      // GestureDetector 로 전체 화면 핀치 인식. 셔터 버튼은 위에 쌓여 있어
      // 별도 GestureDetector 가 우선 처리되므로 셔터 동작과 충돌하지 않는다.
      // 핸들러는 항상 부착 — 줌 미지원/범위 로드 전 가드는 _onScaleUpdate 안에
      // 있으므로, 부착을 조건부로 하면 범위 로드 때마다 rebuild 가 필요해진다.
      body: GestureDetector(
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onTapUp: _onTapFocus,
        child: Stack(
          key: _previewContainerKey,
          fit: StackFit.expand,
          children: [
            _buildPreview(),
            _buildTopBar(),
            IgnorePointer(
              child: Center(
                child: SizedBox(
                  width: _guideBoxWidth,
                  height: _guideBoxHeight,
                  child: CustomPaint(painter: _CornerFramePainter()),
                ),
              ),
            ),
            if (_arBox != null)
              IgnorePointer(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _SingleArBoxPainter(box: _arBox!),
                ),
              ),
            // 탭 포커스 링 — 탭 지점에 잠깐 표시.
            if (_focusIndicator != null)
              Positioned(
                left: _focusIndicator!.dx - 36,
                top: _focusIndicator!.dy - 36,
                child: IgnorePointer(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ),
            // 줌 프리셋 바 — 갤럭시 순정 카메라처럼 셔터 위에 배율 칩
            // (.6 / 1 / 3 등)을 항상 표시. 탭으로 전환, 활성 칩엔 현재 배율.
            if (_maxZoom > _minZoom)
              Positioned(
                bottom: 36 +
                    MediaQuery.of(context).padding.bottom +
                    _shutterDiameter +
                    20,
                left: 0,
                right: 0,
                child: Center(
                  child: _ZoomPresetBar(
                    presets: _zoomPresets,
                    current: _currentZoom,
                    onSelect: _setZoomPreset,
                  ),
                ),
              ),
            Positioned(
              bottom: 36 + MediaQuery.of(context).padding.bottom,
              left: 0,
              right: 0,
              child: Center(
                child: _CaptureButton(onTap: _isCapturing ? null : _onShutter),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final c = _controller;
    // 3중 가드: _isCameraReady 플래그 + controller null + isInitialized.
    // 마지막 isInitialized 는 dispose 직후 build 호출되는 race 에서 stale
    // controller 가 CameraPreview 에 들어가는 것을 차단 → 빨간 화면 방지.
    if (!_isCameraReady ||
        c == null ||
        !c.value.isInitialized ||
        c.value.previewSize == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    // CameraPreview 찌그러짐 방지:
    //   - SizedBox.expand 로 부모 사이즈 채움
    //   - FittedBox(cover) 로 자식 비율 유지하며 cover
    //   - 자식 SizedBox 는 카메라 센서 크기를 명시. portrait 모드에서는
    //     previewSize 가 landscape 기준이라 width/height swap 필수.
    final Size preview = c.value.previewSize!;
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: preview.height, // swap (landscape sensor → portrait UI)
          height: preview.width,
          child: CameraPreview(c),
        ),
      ),
    );
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
              IconButton(
                onPressed: _isCapturing
                    ? null
                    : () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 26),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusMessage,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionDeniedScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
              ),
            ),
            const Spacer(),
            const Icon(Icons.no_photography_outlined,
                size: 72, color: Colors.white38),
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
                '주차 구역 인식을 위해\n카메라 접근 권한을 허용해 주세요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 15,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 36),
            GestureDetector(
              onTap: () {
                _awaitingSettingsReturn = true;
                AppSettings.openAppSettings();
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 36, vertical: 16),
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
}

// ─────────────────────────────────────────────────────────────────────────────
//  Candidate / Painters / Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// 합성 파싱(Combine & Parse) 결과 모델 (v13).
/// - floorType: '지하' / '지상' / null
/// - floorNum : '1'~'9' / null
/// - zone     : 정규식 통과한 zone 문자열 (예: 'B17', 'A1', '13')
/// - box      : zone 매칭 lines 의 union box (AR 박스용)
class _ParseResult {
  final String? floorType;
  final String? floorNum;
  final String zone;
  final Rect box;
  const _ParseResult({
    required this.floorType,
    required this.floorNum,
    required this.zone,
    required this.box,
  });
}

class _SingleArBoxPainter extends CustomPainter {
  final Rect box;
  const _SingleArBoxPainter({required this.box});

  @override
  void paint(Canvas canvas, Size size) {
    if (box.width <= 0 || box.height <= 0) return;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF00E676).withValues(alpha: 0.15);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF00E676);
    final rrect = RRect.fromRectAndRadius(box, const Radius.circular(6));
    canvas.drawRRect(rrect, fill);
    canvas.drawRRect(rrect, stroke);
  }

  @override
  bool shouldRepaint(covariant _SingleArBoxPainter old) => old.box != box;
}

class _CaptureButton extends StatefulWidget {
  final VoidCallback? onTap;
  const _CaptureButton({required this.onTap});

  @override
  State<_CaptureButton> createState() => _CaptureButtonState();
}

class _CaptureButtonState extends State<_CaptureButton> {
  bool _pressed = false;
  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final double d = _CameraScreenState._shutterDiameter;
    final double inner = _pressed ? d - 10 : d;
    final bool enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTap: widget.onTap,
      child: SizedBox(
        width: d,
        height: d,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: inner,
            height: inner,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled
                  ? (_pressed ? const Color(0xFFE5E8EB) : Colors.white)
                  : Colors.white54,
              border: Border.all(color: Colors.white70, width: 4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              Icons.camera_alt_rounded,
              color: enabled
                  ? const Color(0xFF191F28)
                  : const Color(0xFF8B95A1),
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}

class _CopyParams {
  final String src;
  final String dst;
  const _CopyParams(this.src, this.dst);
}

/// NV21 중앙 crop 결과 (bytes + 새 크기).
class _CropResult {
  final Uint8List bytes;
  final int width;
  final int height;
  const _CropResult({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// EXIF(GPS 위치정보 포함) 스트립 + 저장 (Isolate 실행).
///
/// 과거엔 사진 전체를 디코드→재인코드(quality 92)하며 EXIF 를 지웠는데, 순수
/// Dart 디코드/인코드는 800만 화소에서 300~500ms(S24), 구형 폰은 1~2초까지 걸려
/// "사진 저장 중..." 버퍼의 주범이었고 재압축으로 화질 손해도 있었다.
///
/// JPEG 의 GPS 좌표는 APP1(Exif) 세그먼트에만 들어있으므로, 픽셀은 그대로 두고
/// 그 마커 세그먼트만 잘라내면 **무손실 + 수 ms** 로 같은 목적(위치 제거)을
/// 달성한다. 구조 파싱이 예상과 어긋나면 원본을 복사해 저장 자체는 보장한다.
void _stripExifAndSave(_CopyParams p) {
  try {
    final bytes = File(p.src).readAsBytesSync();
    final stripped = _stripJpegExif(bytes);
    File(p.dst).writeAsBytesSync(stripped ?? bytes, flush: true);
  } catch (_) {
    // 어떤 이유든 실패 시 원본 복사 폴백.
    try {
      File(p.src).copySync(p.dst);
    } catch (_) {}
  }
}

/// JPEG 바이트에서 위치정보가 든 APP1(Exif/XMP) 세그먼트를 제거하되,
/// **사진 방향(Orientation)** 만은 보존한 새 바이트를 돌려준다.
///
/// 폰 카메라는 픽셀을 누운 채로 저장하고 "몇 도 돌려 봐라"를 EXIF Orientation
/// 태그로 표시한다. APP1 을 통째로 버리면 그 태그까지 사라져 갤러리가 사진을
/// 돌려서 보여준다. 그래서 원본 Orientation 값만 추출해, GPS·기기모델·시간 등
/// 나머지는 전부 버린 **방향만 담은 최소 Exif** 를 새로 끼워 넣는다.
///
/// JPEG 가 아니거나 구조가 예상과 다르면 null → 호출부가 원본 폴백.
Uint8List? _stripJpegExif(Uint8List b) {
  // SOI 마커(FF D8) 확인.
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;

  int orientation = 0; // 0 = 못 찾음(=방향 태그 추가 안 함)
  final kept = BytesBuilder(); // SOI 다음 세그먼트들(APP1 제외) + SOS 이후 전체
  var i = 2;
  while (i + 1 < b.length) {
    if (b[i] != 0xFF) return null; // 마커 정렬 깨짐 → 폴백
    final marker = b[i + 1];
    // SOS(FF DA): 이후는 압축 영상 데이터 → 통째로 복사하고 종료.
    if (marker == 0xDA) {
      kept.add(b.sublist(i));
      break;
    }
    if (i + 3 >= b.length) return null;
    final segLen = (b[i + 2] << 8) | b[i + 3]; // 길이 2바이트(자신 포함)
    final segEnd = i + 2 + segLen;
    if (segLen < 2 || segEnd > b.length) return null;
    if (marker == 0xE1) {
      // APP1(Exif/XMP, GPS 포함) → 버린다. 단 Exif 면 방향 값만 빼둔다.
      final o = _readExifOrientation(b, i + 4, segEnd);
      if (o != null) orientation = o;
    } else {
      // 그 외(APP0 JFIF, APP2 ICC 컬러프로파일 등 화질·호환에 필요)는 보존.
      kept.add(b.sublist(i, segEnd));
    }
    i = segEnd;
  }

  final out = BytesBuilder();
  out.addByte(0xFF);
  out.addByte(0xD8);
  if (orientation > 0) out.add(_buildOrientationExif(orientation));
  out.add(kept.toBytes());
  return out.toBytes();
}

/// APP1 payload([start], [end)) 에서 Exif Orientation(태그 0x0112) 값만 읽는다.
/// Exif 가 아니거나(XMP 등) 태그가 없으면 null.
int? _readExifOrientation(Uint8List b, int start, int end) {
  // "Exif\0\0" 시그니처 확인.
  if (end - start < 8) return null;
  if (b[start] != 0x45 || b[start + 1] != 0x78 || b[start + 2] != 0x69 ||
      b[start + 3] != 0x66 || b[start + 4] != 0x00 || b[start + 5] != 0x00) {
    return null;
  }
  final tiff = start + 6;
  if (end - tiff < 8) return null;
  final bool little;
  if (b[tiff] == 0x49 && b[tiff + 1] == 0x49) {
    little = true; // "II"
  } else if (b[tiff] == 0x4D && b[tiff + 1] == 0x4D) {
    little = false; // "MM"
  } else {
    return null;
  }
  int u16(int p) =>
      little ? (b[p] | (b[p + 1] << 8)) : ((b[p] << 8) | b[p + 1]);
  int u32(int p) => little
      ? (b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24))
      : ((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]);

  final ifd0 = tiff + u32(tiff + 4);
  if (ifd0 + 2 > end) return null;
  final count = u16(ifd0);
  var p = ifd0 + 2;
  for (var k = 0; k < count; k++) {
    if (p + 12 > end) return null;
    if (u16(p) == 0x0112) return u16(p + 8); // Orientation: SHORT, 값은 p+8
    p += 12;
  }
  return null;
}

/// Orientation 태그 하나만 담은 최소 Exif APP1 세그먼트를 만든다(리틀엔디안).
Uint8List _buildOrientationExif(int orientation) {
  return Uint8List.fromList(<int>[
    0xFF, 0xE1, // APP1 마커
    0x00, 0x22, // 세그먼트 길이 = 34 (자신 포함)
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x49, 0x49, 0x2A, 0x00, // TIFF: "II" + magic 42
    0x08, 0x00, 0x00, 0x00, // IFD0 오프셋 = 8
    0x01, 0x00, // 엔트리 1개
    0x12, 0x01, 0x03, 0x00, // 태그 0x0112(Orientation), 타입 SHORT
    0x01, 0x00, 0x00, 0x00, // count 1
    orientation & 0xFF, (orientation >> 8) & 0xFF, 0x00, 0x00, // 값
    0x00, 0x00, 0x00, 0x00, // 다음 IFD 없음
  ]);
}

class _CornerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0064FF)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const cornerLength = 22.0;
    const radius = 6.0;
    final path = Path();
    path.moveTo(0, cornerLength);
    path.lineTo(0, radius);
    path.quadraticBezierTo(0, 0, radius, 0);
    path.lineTo(cornerLength, 0);
    path.moveTo(size.width - cornerLength, 0);
    path.lineTo(size.width - radius, 0);
    path.quadraticBezierTo(size.width, 0, size.width, radius);
    path.lineTo(size.width, cornerLength);
    path.moveTo(size.width, size.height - cornerLength);
    path.lineTo(size.width, size.height - radius);
    path.quadraticBezierTo(
        size.width, size.height, size.width - radius, size.height);
    path.lineTo(size.width - cornerLength, size.height);
    path.moveTo(cornerLength, size.height);
    path.lineTo(radius, size.height);
    path.quadraticBezierTo(0, size.height, 0, size.height - radius);
    path.lineTo(0, size.height - cornerLength);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 갤럭시 순정 카메라식 줌 프리셋 바 — 반투명 알약 안에 배율 칩(.6 / 1 / 3 등).
/// 활성 칩은 원형 하이라이트 + 현재 배율(예: 1.5x), 비활성 칩은 프리셋 숫자만.
class _ZoomPresetBar extends StatelessWidget {
  final List<double> presets;
  final double current;
  final ValueChanged<double> onSelect;
  const _ZoomPresetBar({
    required this.presets,
    required this.current,
    required this.onSelect,
  });

  /// 현재 배율이 속한 프리셋 인덱스 — 현재 배율 이하 중 가장 큰 프리셋.
  int get _activeIndex {
    var active = 0;
    for (var i = 0; i < presets.length; i++) {
      if (current >= presets[i] - 0.05) active = i;
    }
    return active;
  }

  /// 비활성 칩 라벨 — 갤럭시처럼 "0.6"→".6", "1.0"→"1", "3.0"→"3".
  static String _presetLabel(double z) {
    if (z < 1.0) return '.${(z * 10).round()}';
    final rounded = z.round();
    return (z - rounded).abs() < 0.05 ? '$rounded' : z.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeIndex;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < presets.length; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSelect(presets[i]),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: EdgeInsets.symmetric(
                  horizontal: i == active ? 12 : 9,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: i == active
                      ? Colors.black.withValues(alpha: 0.55)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  i == active
                      ? '${current.toStringAsFixed(1)}x'
                      : _presetLabel(presets[i]),
                  style: TextStyle(
                    color: i == active
                        ? const Color(0xFFFFD54F) // 갤럭시처럼 활성 배율 강조색
                        : Colors.white,
                    fontSize: i == active ? 13 : 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
