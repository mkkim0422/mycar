import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kakao_flutter_sdk_share/kakao_flutter_sdk_share.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:permission_handler/permission_handler.dart';

import 'core/config/app_config.dart';
import 'core/services/notification_service.dart';
import 'core/theme/app_theme.dart';
import 'presentation/pages/camera_screen.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/pages/permission_page.dart';
import 'presentation/pages/settings_page.dart';
import 'presentation/pages/widget_setup_page.dart';
import 'presentation/widgets/bottom_nav_bar.dart';

/// 앱 전역 NavigatorKey.
final _navigatorKey = GlobalKey<NavigatorState>();

/// 홈 화면 위젯 탭 시 홈 데이터 갱신 콜백.
VoidCallback? _goHomeCallback;

/// 카메라 복귀 후 홈 데이터 갱신 콜백.
Future<void> Function()? _reloadHomeCallback;

/// Kotlin Native → Dart 방향 MethodChannel.
const _widgetChannel = MethodChannel('com.snappark/widget');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _widgetChannel.setMethodCallHandler((call) async {
    if (call.method == 'onPayload') {
      final payload = call.arguments as String?;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nav = _navigatorKey.currentState;
        if (nav == null) return;

        if (payload == 'go_home') {
          _goHomeCallback?.call();
        } else if (payload == 'open_camera') {
          // Shell 위에 쌓인 다른 페이지(widget-setup, settings push 등) 를 모두
          // 정리하고 Shell(루트) 위에 /camera 를 push 한다. 저장 후 pop 시
          // 항상 '내차위치' Shell 로 복귀하도록 보장한다.
          nav.popUntil((r) => r.isFirst);
          nav.pushNamed('/camera').then((_) {
            _reloadHomeCallback?.call();
          });
        }
      });
    }
  });

  KakaoSdk.init(nativeAppKey: AppConfig.kakaoNativeAppKey);

  final prefs = await SharedPreferences.getInstance();
  final permissionDone = prefs.getBool('is_permission_requested') ?? false;

  if (permissionDone) {
    await NotificationService.instance.initialize(
      navigatorKey: _navigatorKey,
      onCameraReturn: () async => _reloadHomeCallback?.call(),
    );
  }

  runApp(SnapParkApp(
    initialRoute: permissionDone ? '/' : '/permission',
  ));
}

class SnapParkApp extends StatelessWidget {
  final String initialRoute;

  const SnapParkApp({super.key, required this.initialRoute});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '내차어디',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      navigatorKey: _navigatorKey,
      initialRoute: initialRoute,
      routes: {
        '/': (_) => const ShellScreen(),
        '/camera': (_) => const CameraScreen(),
        '/permission': (_) => const PermissionPage(),
        '/widget-setup': (_) => const WidgetSetupPage(),
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
  int _currentIndex = 0;
  final _homeKey = GlobalKey<HomePageState>();

  @override
  void initState() {
    super.initState();
    _ensureNotificationService();
    _checkWidgetSetup();
    // 내차위치(index 0) 로 시작하므로 FLAG_SECURE 는 반드시 OFF 상태로 초기화.
    // (이전 세션/핫리로드에서 settings 탭이 켰던 잔재를 확실히 제거)
    _setWindowSecure(false);

    _goHomeCallback = () {
      if (mounted) {
        setState(() => _currentIndex = 0);
        _setWindowSecure(false);
        _homeKey.currentState?.reload();
      }
    };

    _reloadHomeCallback = () async {
      if (mounted) {
        setState(() => _currentIndex = 0);
        _setWindowSecure(false);
        await _homeKey.currentState?.reload();
      }
    };
  }

  /// 화면 캡처 차단 플래그를 네이티브 윈도우에 적용한다.
  ///
  /// IndexedStack 은 비활성 탭을 dispose 하지 않으므로, settings 탭이 자체
  /// initState/dispose 에서 토글하면 다른 탭으로 전환해도 플래그가 풀리지 않는
  /// 버그가 발생한다. 탭 전환의 유일한 책임 지점인 ShellScreen 이 관리한다.
  Future<void> _setWindowSecure(bool enabled) async {
    try {
      await _widgetChannel.invokeMethod<void>(
        'setWindowSecure', {'enabled': enabled},
      );
    } catch (_) {
      // 일시적 채널 오류는 무시 — 플래그 실패는 앱 기능에 치명적이지 않다.
    }
  }

  Future<void> _ensureNotificationService() async {
    final prefs = await SharedPreferences.getInstance();
    final permissionDone = prefs.getBool('is_permission_requested') ?? false;
    if (!permissionDone) return;

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
    await Navigator.of(context).pushNamed('/camera');
    if (mounted) await _homeKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomePage(
            key: _homeKey,
            onRegisterTap: _openCamera,
          ),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: SnapParkNavBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          setState(() => _currentIndex = i);
          // 설정 탭(1)에서만 SECURE 플래그 ON — 태깅된 차량 MAC 등 민감정보
          // 노출 방지. 내차위치 탭(0)에선 OFF 라 사용자가 사진/위치를 캡처·공유할 수 있다.
          _setWindowSecure(i == 1);
        },
      ),
    );
  }
}
