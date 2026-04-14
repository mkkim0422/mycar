import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ── Payload 상수 ─────────────────────────────────────────────────────────────
// BluetoothDisconnectReceiver.kt의 PAYLOAD_OPEN_CAMERA 값과 동일해야 한다.
const _kPayloadOpenCamera = 'open_camera';

// ── 알림 채널 (BluetoothDisconnectReceiver.kt와 동일한 Channel ID) ────────────
const _kChannelId = 'snappark_bt_channel';
const _kChannelName = '주차 위치 알림';

/// Flutter 단에서 알림 권한 요청 및 알림 탭 라우팅을 담당하는 서비스.
///
/// ## 사용 방법
/// ```dart
/// // main() 또는 앱 루트에서 한 번만 초기화
/// await NotificationService.instance.initialize(navigatorKey: _navigatorKey);
/// await NotificationService.instance.requestPermissions();
/// ```
///
/// ## 설계 원칙
/// - 알림 **발송**은 Android Native [BluetoothDisconnectReceiver]가 담당한다.
///   Flutter에서는 권한 요청 + 탭 이벤트 라우팅만 처리한다.
/// - [GlobalKey<NavigatorState>]를 주입받아 BuildContext 없이도 라우팅한다.
class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  GlobalKey<NavigatorState>? _navigatorKey;

  /// 서비스를 초기화한다.
  ///
  /// [navigatorKey]: 알림 탭 시 라우팅에 사용할 NavigatorKey.
  ///   앱 루트 [MaterialApp.navigatorKey]에 연결된 키를 전달해야 한다.
  Future<void> initialize({required GlobalKey<NavigatorState> navigatorKey}) async {
    _navigatorKey = navigatorKey;

    const androidSettings = AndroidInitializationSettings(
      // Android 8.0+ 적응형 아이콘 또는 단색 아이콘 리소스명 (확장자 제외)
      // 현재는 기본 Android 아이콘 사용; 실제 배포 시 앱 아이콘으로 교체 필요
      '@mipmap/ic_launcher',
    );

    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
      // 앱이 종료된 상태에서 알림을 탭한 경우도 처리
      onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationTap,
    );

    // 앱이 완전히 종료된 상태에서 알림을 탭해 실행된 경우 처리
    await _handleLaunchNotification();
  }

  /// Android 13+(API 33+) 런타임 알림 권한을 요청한다.
  ///
  /// 이미 권한이 부여된 경우 다이얼로그를 띄우지 않는다.
  /// 반환값: 권한이 부여되었으면 true, 거부되었으면 false.
  Future<bool> requestPermissions() async {
    final androidPlugin =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin == null) return false;

    final granted = await androidPlugin.requestNotificationsPermission();
    return granted ?? false;
  }

  /// 앱이 포그라운드에 있을 때도 테스트용으로 알림을 즉시 발송한다.
  ///
  /// 실제 블루투스 연결 해제 알림은 Native [BluetoothDisconnectReceiver]가 발송하며,
  /// 이 메서드는 개발/QA 단계에서 알림 동작을 검증할 때 사용한다.
  Future<void> showParkingReminderNotification() async {
    const androidDetails = AndroidNotificationDetails(
      _kChannelId,
      _kChannelName,
      channelDescription: '블루투스 연결 해제 시 주차 위치 기록을 유도하는 알림',
      importance: Importance.high,
      priority: Priority.high,
      ticker: '주차 위치를 기록하세요',
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      1001, // BluetoothDisconnectReceiver.NOTIFICATION_ID와 동일
      '주차하셨나요?',
      '위치를 기록해두세요! 탭하면 카메라가 열립니다.',
      details,
      payload: _kPayloadOpenCamera,
    );
  }

  // ── 내부 핸들러 ────────────────────────────────────────────────────────────

  /// 앱이 포그라운드/백그라운드 상태에서 알림을 탭했을 때 호출.
  void _onNotificationTap(NotificationResponse response) {
    _route(response.payload);
  }

  /// 앱이 완전히 종료된 상태에서 알림을 탭해 앱이 실행된 경우 처리.
  Future<void> _handleLaunchNotification() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp == true) {
      final payload = details!.notificationResponse?.payload;
      // 라우팅은 첫 프레임 이후 실행해야 Navigator가 준비됨
      WidgetsBinding.instance.addPostFrameCallback((_) => _route(payload));
    }
  }

  /// payload 값에 따라 적절한 화면으로 이동한다.
  void _route(String? payload) {
    if (payload == null) return;
    final navigator = _navigatorKey?.currentState;
    if (navigator == null) return;

    switch (payload) {
      case _kPayloadOpenCamera:
        // 카메라 화면을 스택 위에 push
        // import는 사용처에서 처리하고, 여기서는 named route 방식 사용
        navigator.pushNamed('/camera');
    }
  }
}

// ── Top-level 백그라운드 핸들러 ───────────────────────────────────────────────
// @pragma('vm:entry-point') 어노테이션 필수:
// Tree-shaking으로 제거되지 않도록 보호한다.
@pragma('vm:entry-point')
void _onBackgroundNotificationTap(NotificationResponse response) {
  // 백그라운드 핸들러는 별도 Isolate에서 실행되므로 UI 조작 불가.
  // payload 로깅 또는 SharedPreferences 기록 정도만 수행한다.
  // 실제 라우팅은 앱이 포그라운드로 복귀할 때 _handleLaunchNotification이 처리.
  debugPrint('[NotificationService] Background tap: ${response.payload}');
}
