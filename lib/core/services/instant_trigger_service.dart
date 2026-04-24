import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 블루투스/CarPlay 연결 해제 시 가속도계 기반 모션 감지를 통해
/// 최소 지연(< 3초)으로 주차 알림을 발송하는 즉시 트리거 서비스.
///
/// ## 아키텍처
/// 핵심 로직은 Native Kotlin [MotionDetectionService]에서 실행된다.
/// 앱이 종료된 상태에서도 동작해야 하므로 센서 감지 → 알림 발송이
/// 모두 Android 네이티브 레이어에서 처리된다.
///
/// 이 Dart 클래스는 다음을 담당한다:
/// - **설정 관리**: 활성화/비활성화, 임계값 조정 (SharedPreferences)
/// - **테스트 트리거**: MethodChannel 을 통해 모션 감지 서비스를 수동 시작
///
/// ## 동작 흐름
/// ```
/// BT Disconnect (OS Broadcast)
///   → BluetoothDisconnectReceiver.onReceive()
///     → MotionDetectionService.start() (foreground service)
///       → 가속도계 모니터링 (300ms baseline → delta 비교)
///         → |Δmag| > threshold → 즉시 고우선 알림 발송 (< 3초)
///         → 10초 정지 → 대기 모드 (다음 모션까지 보류)
///         → 2분 타임아웃 → 무조건 알림 발송
/// ```
///
/// ## SharedPreferences 키 (Native 에서도 읽음)
/// - `instant_trigger_enabled` : bool (기본 true)
/// - `instant_trigger_threshold` : double, m/s² (기본 1.0)
class InstantTriggerService {
  static const _channel = MethodChannel('com.snappark/widget');
  static const _enabledKey = 'instant_trigger_enabled';
  static const _thresholdKey = 'instant_trigger_threshold';

  /// 기본 모션 감지 임계값 (m/s²).
  ///
  /// 중력(~9.8) 기준, 폰을 살짝 들거나 틸트 시 Δmag ≈ 0.5~1.5.
  /// 주머니에 넣으며 걷기 시작하면 Δmag ≈ 2~5.
  /// 1.0은 "의도적 움직임"의 시작을 포착하는 최적 구간.
  static const defaultThreshold = 1.0;

  // ── 활성화 설정 ─────────────────────────────────────────────────────────

  /// 즉시 트리거(모션 감지 기반 알림) 활성화 여부를 반환한다.
  /// 기본값: true (활성화).
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  /// 즉시 트리거를 활성화/비활성화한다.
  ///
  /// 비활성화하면 BT 연결 해제 시 모션 감지 없이 **즉시** 알림이 발송된다
  /// (레거시 동작과 동일).
  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
  }

  // ── 임계값 설정 ─────────────────────────────────────────────────────────

  /// 현재 모션 감지 임계값을 반환한다 (m/s²).
  static Future<double> getThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_thresholdKey) ?? defaultThreshold;
  }

  /// 모션 감지 임계값을 설정한다 (m/s²).
  ///
  /// - 낮은 값(0.5): 민감 — 작은 진동에도 반응. 차량 엔진 진동에 오탐 가능.
  /// - 기본값(1.0): 균형 — 폰을 들거나 틸트할 때 반응.
  /// - 높은 값(2.0): 둔감 — 확실한 보행 동작에서만 반응.
  static Future<void> setThreshold(double threshold) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_thresholdKey, threshold);
  }

  // ── 테스트 ──────────────────────────────────────────────────────────────

  /// BT 연결 해제를 시뮬레이션하여 모션 감지 서비스를 수동 시작한다.
  ///
  /// 개발/QA 용도. 서비스가 시작되면 가속도계 모니터링이 시작되며,
  /// 폰을 움직이면 실제 주차 알림이 발송된다.
  static Future<void> testTrigger() async {
    try {
      await _channel.invokeMethod<void>('testMotionTrigger');
    } catch (e) {
      debugPrint('[InstantTriggerService] testTrigger 실패: $e');
    }
  }
}
