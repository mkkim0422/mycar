import 'package:flutter/material.dart';
import 'package:kakao_flutter_sdk_share/kakao_flutter_sdk_share.dart';

import 'core/config/app_config.dart';
import 'core/services/notification_service.dart';
import 'core/theme/app_theme.dart';
import 'presentation/pages/camera_screen.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/pages/settings_page.dart';
import 'presentation/widgets/bottom_nav_bar.dart';

/// 앱 전역 NavigatorKey.
/// NotificationService가 BuildContext 없이 라우팅할 때 사용한다.
final _navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 배포 전 AppConfig.kakaoNativeAppKey를 실제 키로 교체하세요.
  // 설정 방법은 lib/core/config/app_config.dart 주석을 참고하세요.
  KakaoSdk.init(nativeAppKey: AppConfig.kakaoNativeAppKey);

  await NotificationService.instance.initialize(navigatorKey: _navigatorKey);
  runApp(const SnapParkApp());
}

class SnapParkApp extends StatelessWidget {
  const SnapParkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '내차어디',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      navigatorKey: _navigatorKey,
      routes: {
        '/': (_) => const ShellScreen(),
        '/camera': (_) => const CameraScreen(),
      },
      initialRoute: '/',
    );
  }
}

/// 하단 내비게이션을 포함한 앱 Shell.
///
/// 탭 전환은 IndexedStack으로 처리해 각 페이지의 상태(스크롤 위치 등)를 보존한다.
/// 카메라 화면은 Shell 위에 fullscreen으로 push 된다.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _currentIndex = 0;

  /// GlobalKey<HomePageState>: 카메라 복귀 후 홈 데이터 갱신에 사용.
  final _homeKey = GlobalKey<HomePageState>();

  @override
  void initState() {
    super.initState();
    NotificationService.instance.requestPermissions();
  }

  Future<void> _openCamera() async {
    final result = await Navigator.of(context).pushNamed('/camera');

    // 카메라에서 데이터와 함께 돌아오면 홈 새로고침 + 홈 탭으로 이동
    if (result is CameraResult && mounted) {
      await _homeKey.currentState?.reload();
      setState(() => _currentIndex = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          // 탭 0: 홈 — GlobalKey로 reload() 접근
          HomePage(
            key: _homeKey,
            onRegisterTap: _openCamera,
          ),
          // 탭 1: 위젯 (6단계에서 네이티브 위젯 관리 UI로 교체)
          const _WidgetPlaceholderPage(),
          // 탭 2: 설정
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: SnapParkNavBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
      ),
    );
  }
}

/// 위젯 탭 플레이스홀더 (6단계: 네이티브 AppWidget 관리 화면으로 교체 예정).
class _WidgetPlaceholderPage extends StatelessWidget {
  const _WidgetPlaceholderPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      appBar: AppBar(
        backgroundColor: AppTheme.gray100,
        title: const Text('위젯'),
      ),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.widgets_outlined, size: 56, color: AppTheme.gray500),
            SizedBox(height: 16),
            Text(
              '홈 화면 위젯',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.gray900,
              ),
            ),
            SizedBox(height: 8),
            Text(
              '6단계에서 네이티브 위젯이 추가됩니다.',
              style: TextStyle(fontSize: 14, color: AppTheme.gray500),
            ),
          ],
        ),
      ),
    );
  }
}
