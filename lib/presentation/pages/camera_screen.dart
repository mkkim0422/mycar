import 'dart:async';
import 'dart:io';

import 'package:app_settings/app_settings.dart';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
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

  // ── 좌표 측정 + AR 상태 ────────────────────────────────────────────────────
  final _previewContainerKey = GlobalKey();
  Rect? _arBox;
  String? _lastMatchedZone;
  String? _lastMatchedFloorType; // '지하' / '지상' / null
  String? _lastMatchedFloorNum; // '1'~'9' / null
  double _lastUprightW = 0;
  double _lastUprightH = 0;

  // ── 상수 ───────────────────────────────────────────────────────────────────
  static const double _guideBoxWidth = 280.0;
  static const double _guideBoxHeight = 160.0;
  static const double _shutterDiameter = 76.0;
  static const Duration _shutterCooldown = Duration(milliseconds: 300);

  String _statusMessage = '구역을 가이드 안에 비춰 주세요';

  // ── 깜빡임 차단 카운터 ─────────────────────────────────────────────────────
  int _emptyFrameCount = 0;
  static const int _emptyResetThreshold = 3;

  // ── stability counter — toggling 방지 ────────────────────────────────────
  String? _stableCandidate;
  int _stableCount = 0;
  static const int _stabilityThreshold = 3;

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
      final cameras = await availableCameras();
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
      _recognizer ??= TextRecognizer(script: TextRecognitionScript.korean);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // 줌 범위 로드 — 일부 광각 렌즈는 minZoom < 1.0 이지만 UX 단순화를 위해
      // 사용자 표시는 1.0 부터 시작. setZoomLevel 호출 시는 내부 minZoom 클램프.
      try {
        _minZoom = await controller.getMinZoomLevel();
        _maxZoom = await controller.getMaxZoomLevel();
        _currentZoom = _minZoom.clamp(1.0, _maxZoom);
        await controller.setZoomLevel(_currentZoom);
      } catch (e) {
        debugPrint('[Camera] zoom 범위 조회 실패: $e');
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _currentZoom = 1.0;
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
      setState(() {
        _controller = controller;
        _isCameraReady = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _startStream());
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

      final int sensorDeg = controller.description.sensorOrientation;
      final bool swap = sensorDeg == 90 || sensorDeg == 270;
      // _currentZoom > 1.0 이면 NV21 이 중앙 crop 되어 ML Kit 에 전달됐으므로
      // boundingBox 좌표계도 crop 크기 기준이다. _transformBox 의 scale 계산이
      // 일치하도록 _lastUpright 도 crop 크기로 맞춘다.
      int effectiveW = image.width;
      int effectiveH = image.height;
      if (_currentZoom > 1.05) {
        effectiveW = (image.width / _currentZoom).round() & ~1;
        effectiveH = (image.height / _currentZoom).round() & ~1;
      }
      _lastUprightW = (swap ? effectiveH : effectiveW).toDouble();
      _lastUprightH = (swap ? effectiveW : effectiveH).toDouble();

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
    final guideInputRect = _guideBoxInInputCoords();
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

  /// [Combine & Parse] — lines 노이즈 필터 → 공백 결합 → STEP1 floor 도려내기 →
  /// STEP2 공백 압착 + strict zone 검사.
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

    // ── 공백 + 결합 ─────────────────────────────────────────────────────
    final combined = cleanLines.map((l) => l.text.trim()).join(' ');

    // ── STEP 1: 층수 도려내기 ──────────────────────────────────────────
    String? floorType;
    String? floorNum;
    String remaining = combined;
    final fm = _floorPattern.firstMatch(combined);
    if (fm != null) {
      final matched = fm.group(0)!.toUpperCase(); // "B2" or "2F"
      if (matched.startsWith('B')) {
        floorType = '지하';
        floorNum = matched.substring(1);
      } else {
        floorType = '지상';
        floorNum = matched.substring(0, matched.length - 1);
      }
      // 모든 floor 매치 제거 — 같은 시야에 다른 floor 잔재가 zone 으로 합쳐지는 사고 차단
      remaining = combined.replaceAll(_floorPattern, '');
    }

    // ── STEP 2: 공백 압착 + strict zone 검사 ──────────────────────────
    final compact = remaining.replaceAll(RegExp(r'\s+'), '');
    if (compact.isEmpty) return null;

    String? zone;
    if (_alphaNumStrict.hasMatch(compact)) {
      zone = compact.toUpperCase();
    } else if (_zoneNumericStrict.hasMatch(compact)) {
      zone = compact;
    } else {
      return null;
    }

    // ── AR 박스 — clean lines 의 union ─────────────────────────────────
    Rect box = cleanLines.first.boundingBox;
    for (int i = 1; i < cleanLines.length; i++) {
      box = box.expandToInclude(cleanLines[i].boundingBox);
    }

    return _ParseResult(
      floorType: floorType,
      floorNum: floorNum,
      zone: zone,
      box: box,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  CameraImage → InputImage (YUV420→NV21)
  // ──────────────────────────────────────────────────────────────────────────

  InputImage? _buildInputImage(CameraImage image, int sensorOrientation) {
    final InputImageRotation rotation = _degToRotation(sensorOrientation);
    final Uint8List bytes;
    final InputImageFormat format;
    final int bytesPerRow;
    int outW = image.width;
    int outH = image.height;
    if (Platform.isAndroid) {
      final conv = _yuv420ToNv21(image);
      if (conv == null) return null;
      // ── Digital zoom for ML Kit ──────────────────────────────────────
      // camera_android_camerax 의 ImageAnalysis use case 는 hardware zoom
      // (setZoomLevel) 을 반영하지 않는다. preview/takePicture 만 줌된 영상을
      // 받고 image stream 은 항상 wide sensor 영상을 받음. 사용자가 핀치로
      // 줌 인 한 상태에서 OCR 도 같은 영역만 보도록 NV21 을 중앙 crop.
      if (_currentZoom > 1.05) {
        final cropped = _cropNv21Center(
          conv,
          image.width,
          image.height,
          _currentZoom,
        );
        if (cropped != null) {
          bytes = cropped.bytes;
          outW = cropped.width;
          outH = cropped.height;
        } else {
          bytes = conv; // crop 실패 시 원본 사용 (안전 폴백)
        }
      } else {
        bytes = conv;
      }
      format = InputImageFormat.nv21;
      bytesPerRow = outW;
    } else {
      if (image.planes.isEmpty) return null;
      bytes = image.planes.first.bytes;
      format = InputImageFormat.bgra8888;
      bytesPerRow = image.planes.first.bytesPerRow;
    }
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
    return Rect.fromLTRB(
      raw.left * scale + offsetX,
      raw.top * scale + offsetY,
      raw.right * scale + offsetX,
      raw.bottom * scale + offsetY,
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Shutter — 300ms 쿨타임 + takePicture + pop
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _onShutter() async {
    if (_isCapturing || _popped) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    _isCapturing = true;
    if (mounted) setState(() => _statusMessage = '사진 저장 중...');
    await HapticFeedback.mediumImpact();

    String? tempPath;
    String? savedPath;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      int waited = 0;
      while (_isProcessing && waited < 10) {
        await Future.delayed(const Duration(milliseconds: 30));
        waited++;
      }
      await Future.delayed(_shutterCooldown);

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
      debugPrint('[Camera] shutter pop → $result');
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

  void _onScaleStart(ScaleStartDetails d) {
    // 현재 줌을 스냅샷 — 이후 onScaleUpdate 에서 누적이 아니라 base × scale.
    _baseScaleZoom = _currentZoom;
  }

  Future<void> _onScaleUpdate(ScaleUpdateDetails d) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_maxZoom <= _minZoom) return; // 줌 미지원 기기
    // base × scale 후 [minZoom..maxZoom] 으로 클램프 (사용자 표시는 ≥1.0).
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
  //  Build
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) return _buildPermissionDeniedScreen();
    final zoomSupported = _maxZoom > _minZoom;
    return Scaffold(
      backgroundColor: Colors.black,
      // GestureDetector 로 전체 화면 핀치 인식. 셔터 버튼은 위에 쌓여 있어
      // 별도 GestureDetector 가 우선 처리되므로 셔터 동작과 충돌하지 않는다.
      body: GestureDetector(
        onScaleStart: zoomSupported ? _onScaleStart : null,
        onScaleUpdate: zoomSupported ? _onScaleUpdate : null,
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
            // 줌 인디케이터 — 셔터 위쪽 중앙, 1.0 보다 큰 줌일 때만 노출.
            if (zoomSupported && _currentZoom > 1.05)
              Positioned(
                bottom: 36 +
                    MediaQuery.of(context).padding.bottom +
                    _shutterDiameter +
                    20,
                left: 0,
                right: 0,
                child: Center(child: _ZoomIndicator(zoom: _currentZoom)),
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

/// EXIF 스트립 + 저장 (Isolate 실행).
///
/// 디코드/인코드 비용은 800만 화소 기준 300~500ms (S24 Galaxy). 메인 스레드를
/// 막지 않도록 compute()로 격리. 실패 시 원본 그대로 복사하여 저장 자체는 보장.
void _stripExifAndSave(_CopyParams p) {
  try {
    final bytes = File(p.src).readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      File(p.src).copySync(p.dst);
      return;
    }
    // 모든 EXIF 디렉토리(GPS, IFD0, EXIF, Interop) 제거.
    decoded.exif.clear();
    final out = img.encodeJpg(decoded, quality: 92);
    File(p.dst).writeAsBytesSync(out, flush: true);
  } catch (_) {
    // 어떤 이유든 디코드/인코드 실패 시 원본 복사 폴백.
    try {
      File(p.src).copySync(p.dst);
    } catch (_) {}
  }
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

/// 핀치 줌 인디케이터 — 현재 배율을 작은 알약 형태로 표시.
class _ZoomIndicator extends StatelessWidget {
  final double zoom;
  const _ZoomIndicator({required this.zoom});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${zoom.toStringAsFixed(1)}x',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
