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

    _goHomeCallback = () {
      if (mounted) {
        setState(() => _currentIndex = 0);
        _homeKey.currentState?.reload();
      }
    };

    _reloadHomeCallback = () async {
      if (mounted) {
        setState(() => _currentIndex = 0);
        await _homeKey.currentState?.reload();
      }
    };
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
        },
      ),
    );
  }
}
