import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:permission_handler/permission_handler.dart';

import 'core/navigation/route_observer.dart';
import 'core/services/billing_service.dart';
import 'core/services/notification_service.dart';
import 'core/theme/app_theme.dart';
import 'presentation/pages/camera_screen.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/pages/parking_input_page.dart';
import 'presentation/pages/permission_page.dart';
import 'presentation/pages/settings_page.dart';
import 'presentation/pages/widget_setup_page.dart';
import 'presentation/widgets/ad_banner.dart';

/// 앱 전역 NavigatorKey.
final _navigatorKey = GlobalKey<NavigatorState>();

/// 홈 화면 위젯 탭 시 홈 데이터 갱신 콜백.
VoidCallback? _goHomeCallback;

/// 카메라 복귀 후 홈 데이터 갱신 콜백.
Future<void> Function()? _reloadHomeCallback;

/// 카메라 ↔ 입력 페이지 사이를 오가는 루프 (v11 부활).
///
///   1) 카메라 pop {zone, imagePath} 받음
///   2) imagePath 있으면 ParkingInputPage push
///   3) ParkingInputPage [저장] → pop(true) → 루프 종료 + home reload
///   4) ParkingInputPage [다시 촬영]/back → pop(false) → 카메라 재push
///   5) 카메라 X 닫기 → result null → 루프 종료 + reload
Future<void> _handleCameraResultAndReload(
  NavigatorState nav,
  Object? initialResult,
) async {
  Object? result = initialResult;
  while (true) {
    debugPrint('[Main] loop result = $result');
    if (result is! Map) break;
    final zone = result['zone']?.toString() ?? '';
    final imagePath = result['imagePath']?.toString() ?? '';
    // floorType: '지하' / '지상' / 빈 문자열(없음)
    final rawFloorType = result['floorType']?.toString() ?? '';
    final floorType = rawFloorType.isEmpty ? null : rawFloorType;
    final rawFloorNum = result['floorNum']?.toString() ?? '';
    final floorNum = rawFloorNum.isEmpty ? null : rawFloorNum;
    if (imagePath.isEmpty) break;
    // 카메라 → 입력 페이지 전환도 즉각 (슬라이드 애니메이션 제거).
    final saved = await nav.push<bool>(PageRouteBuilder<bool>(
      pageBuilder: (_, __, ___) => ParkingInputPage(
        photoPath: imagePath,
        prefilledZone: zone,
        prefilledFloorType: floorType,
        prefilledFloorNum: floorNum,
      ),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ));
    debugPrint('[Main] ParkingInputPage closed — saved=$saved');
    if (saved == true) break;
    // saved == false / null → 다시 촬영 → 카메라 재push
    result = await nav.pushNamed('/camera');
  }
  // await 로 reload 가 끝날 때까지 기다린다. 누락(currentState null) 케이스는
  // RouteObserver(appRouteObserver) 가 별도로 didPopNext 를 통해 커버한다.
  final cb = _reloadHomeCallback;
  if (cb != null) await cb();
}

/// AdMob SDK 초기화 + UMP(GDPR) 동의 폼 표시.
///
/// 두 작업은 **반드시 병렬**로 실행한다. UMP 응답을 기다려서 initialize 를
/// 호출하면 AdBanner 가 SDK 초기화 전에 load 를 시도해 실패 → 배너가 안 보임.
/// UMP 는 광고 SDK 가 내부적으로 동의 상태를 참조해 개인화/비개인화를 결정하므로
/// 별도 await 불필요.
Future<void> _initAdsWithConsent() async {
  // 1) SDK 초기화 — 즉시 시작(비차단). 완료 후 콘텐츠 등급(PG) 적용.
  unawaited(MobileAds.instance.initialize().then((_) async {
    try {
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(maxAdContentRating: MaxAdContentRating.pg),
      );
    } catch (_) {}
  }));

  // 2) UMP 동의 — EEA/UK/스위스 외 지역은 NOT_REQUIRED 로 즉시 no-op.
  //    오류·예외 모두 무시(광고 송출에 영향 없음).
  try {
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () async {
        try {
          await ConsentForm.loadAndShowConsentFormIfRequired((_) {});
        } catch (_) {}
      },
      (FormError _) {},
    );
  } catch (_) {}
}

/// Kotlin Native → Dart 방향 MethodChannel.
const _widgetChannel = MethodChannel('com.snappark/widget');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // AdMob 초기화 + GDPR(UMP) 동의 처리.
  //
  // iOS 는 Info.plist 의 GADApplicationIdentifier 가 설정되어 있어야 SDK 가
  // 정상 동작한다. 현재 AdBanner 는 Platform.isAndroid 가드로 iOS 노출을
  // 막고 있으므로 초기화 자체도 Android 만 수행한다.
  //
  // ## UMP(User Messaging Platform) 동의 흐름
  // - EEA/UK/스위스 사용자: 최초 실행 시 동의 폼 자동 표시 → 동의 결과에 따라
  //   개인화/비개인화 광고 분기. 동의 거부도 광고는 송출(비개인화).
  // - 그 외 지역(한국 포함): requestConsentInfoUpdate 가 NOT_REQUIRED 반환 →
  //   폼 호출은 즉시 no-op → 그대로 광고 초기화.
  // - 네트워크 오류·예외 시에도 광고 초기화는 진행(서비스 가용성 우선).
  if (Platform.isAndroid) {
    unawaited(_initAdsWithConsent());
  }

  // 광고 제거 결제 — 영속 플래그 로드 + 상품 조회 + 구매 복원/스트림 구독.
  // 스토어 미설정·오프라인에서도 graceful(배너는 폴백 동작).
  unawaited(BillingService.instance.init());

  _widgetChannel.setMethodCallHandler((call) async {
    if (call.method == 'onPayload') {
      final payload = call.arguments as String?;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final nav = _navigatorKey.currentState;
        if (nav == null) return;

        if (payload == 'go_home') {
          _goHomeCallback?.call();
        } else if (payload == 'open_camera') {
          // Shell 위에 쌓인 다른 페이지(widget-setup, settings push 등) 를 모두
          // 정리하고 Shell(루트) 위에 /camera 를 push 한다. 카메라가 pop 한
          // 결과({zone, imagePath}) 를 받아 ParkingInputPage 로 이어주고,
          // 입력 페이지가 닫히면 home 을 reload 한다.
          //
          // ── 위젯 콜드 스타트 race 방어 ─────────────────────────────────────
          //   앱이 종료된 상태에서 위젯 탭 시 lifecycle 이 inactive→resumed 로
          //   토글되는 구간에 /camera 가 push 되면 CameraScreen 의 lifecycle
          //   observer 와 initState 가 _initCamera() 를 동시에 호출하는 race 가
          //   발생 → 빨간 화면(CameraException disposed CameraController).
          //   첫 프레임이 끝난 뒤 한 박자 더 기다려 lifecycle 을 안정화한다.
          await Future.delayed(const Duration(milliseconds: 80));
          final nav2 = _navigatorKey.currentState;
          if (nav2 == null) return;
          nav2.popUntil((r) => r.isFirst);
          final cameraResult = await nav2.pushNamed('/camera');
          await _handleCameraResultAndReload(nav2, cameraResult);
        }
      });
    }
  });

  final prefs = await SharedPreferences.getInstance();
  // 온보딩 통과 조건: 약관(필수 2종) 동의 + OS 권한 다이얼로그 1회 이상 진행.
  // 이전 빌드에서 권한만 받고 약관 추가 전에 깔린 사용자도 약관 단계로 보낸다.
  final agreedPrivacy = prefs.getBool('agreed_privacy') ?? false;
  final agreedLocation = prefs.getBool('agreed_location') ?? false;
  final permissionDone = prefs.getBool('is_permission_requested') ?? false;
  final onboardingDone = agreedPrivacy && agreedLocation && permissionDone;

  if (onboardingDone) {
    await NotificationService.instance.initialize(
      navigatorKey: _navigatorKey,
      onCameraReturn: () async => _reloadHomeCallback?.call(),
    );
  }

  runApp(SnapParkApp(
    initialRoute: onboardingDone ? '/' : '/permission',
  ));
}

class SnapParkApp extends StatelessWidget {
  final String initialRoute;

  const SnapParkApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '주차기억',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      navigatorKey: _navigatorKey,
      // 카메라/입력 페이지 pop 시 HomePage 가 자동 reload 하도록 RouteObserver 등록.
      // 기존 _reloadHomeCallback 보조 안전망 — _homeKey.currentState 가 null 인
      // edge case 에서도 홈이 데이터 갱신을 놓치지 않게 한다.
      navigatorObservers: [appRouteObserver],
      initialRoute: initialRoute,
      routes: {
        '/': (_) => const ShellScreen(),
        // '/camera' 는 onGenerateRoute 에서 zero-anim PageRoute 로 가로챈다.
        '/permission': (_) => const PermissionPage(),
        '/widget-setup': (_) => const WidgetSetupPage(),
        '/settings': (_) => const SettingsPage(),
      },
      // 카메라 진입 시 슬라이드 애니메이션을 없애 즉각 전환되도록 한다.
      // pushNamed('/camera') 호출이 4곳 (홈 신규등록, 위젯, 알림 탭, 재촬영 루프)
      // 이라 routes 에서 빼고 한 곳에서 처리하는 게 깔끔하다.
      onGenerateRoute: (settings) {
        if (settings.name == '/camera') {
          return PageRouteBuilder(
            settings: settings,
            pageBuilder: (_, __, ___) => const CameraScreen(),
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
          );
        }
        return null;
      },
    );
  }
}

/// 2탭 Shell: 주차등록(홈) + 설정.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  final _homeKey = GlobalKey<HomePageState>();

  @override
  void initState() {
    super.initState();
    _ensureNotificationService();
    _checkWidgetSetup();

    // 홈이 단독 화면이므로 탭 전환 없이 데이터만 새로고침한다.
    _goHomeCallback = () {
      _homeKey.currentState?.reload();
    };

    _reloadHomeCallback = () async {
      await _homeKey.currentState?.reload();
    };
  }

  Future<void> _ensureNotificationService() async {
    final prefs = await SharedPreferences.getInstance();
    final agreedPrivacy = prefs.getBool('agreed_privacy') ?? false;
    final agreedLocation = prefs.getBool('agreed_location') ?? false;
    final permissionDone = prefs.getBool('is_permission_requested') ?? false;
    if (!(agreedPrivacy && agreedLocation && permissionDone)) return;

    await NotificationService.instance.initialize(
      navigatorKey: _navigatorKey,
      onCameraReturn: () async => _reloadHomeCallback?.call(),
    );
    NotificationService.instance.requestPermissions();

    final btStatus = await Permission.bluetoothConnect.status;
    if (!btStatus.isGranted) {
      await Permission.bluetoothConnect.request();
    }
  }

  /// 설치 직후 **최초 1회만** 위젯 설정 페이지를 자동 표시한다.
  ///
  /// 이전 로직은 `is_widget_setup_done` (실제 pin 완료 여부) 를 기준으로 해서
  /// 사용자가 위젯 추가를 건너뛰면 매 실행마다 위젯 페이지가 다시 떴다. 여기선
  /// 별도 intro 플래그(`has_shown_widget_intro`) 를 **push 직전에 먼저** 저장해
  /// 추가 여부와 무관하게 두 번째 실행부터 항상 홈(내차위치) 으로 진입하게 한다.
  Future<void> _checkWidgetSetup() async {
    final prefs = await SharedPreferences.getInstance();

    // 안전망 — 약관 미동의 또는 권한 미진행 상태에서는 위젯 안내를 띄우지
    // 않는다. 이전 빌드에서 `is_permission_requested=true` 만 박힌 사용자가
    // 새 빌드 진입 시 위젯 화면부터 보이는 회귀 차단.
    final agreedPrivacy = prefs.getBool('agreed_privacy') ?? false;
    final agreedLocation = prefs.getBool('agreed_location') ?? false;
    final permissionDone = prefs.getBool('is_permission_requested') ?? false;
    if (!(agreedPrivacy && agreedLocation && permissionDone)) return;

    if (prefs.getBool('has_shown_widget_intro') ?? false) return;

    // 마커를 먼저 저장 — push 가 실패하거나 사용자가 강제 종료해도 재노출 방지.
    await prefs.setBool('has_shown_widget_intro', true);

    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pushNamed('/widget-setup');
    });
  }

  @override
  void dispose() {
    _goHomeCallback = null;
    _reloadHomeCallback = null;
    super.dispose();
  }

  Future<void> _openCamera() async {
    // 카메라가 결과 없이 닫혔으면 단순 reload. 결과({zone, imagePath}) 가
    // 돌아오면 ParkingInputPage 로 이어서 push 한다.
    final cameraResult = await Navigator.of(context).pushNamed('/camera');
    if (!mounted) return;
    await _handleCameraResultAndReload(Navigator.of(context), cameraResult);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      body: HomePage(
        key: _homeKey,
        onRegisterTap: _openCamera,
      ),
      // 기존 하단 네비게이션 바가 있던 자리 → 광고 배너.
      // 설정은 이 위로 push 되는 풀스크린이라 배너는 홈에서만 노출된다.
      bottomNavigationBar: const AdBanner(),
    );
  }
}
