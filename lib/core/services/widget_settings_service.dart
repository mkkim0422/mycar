import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 홈 화면 위젯 디스플레이 타입.
///
/// Native([WidgetDisplayType] enum in Kotlin)의 `fromKey` 와 반드시 키가 일치해야 한다.
enum WidgetDisplayType {
  /// 풀블리드 사진 + 정보 오버레이 (첨부 스크린샷 스타일 · 기본값)
  photoInfo,

  /// 사진만 풀블리드. 텍스트 숨김.
  photoOnly,

  /// 파란 배경 + 텍스트만. 사진 숨김.
  infoOnly;

  /// SharedPreferences 에 저장되는 문자열 키 (Kotlin `WidgetDisplayType.fromKey` 와 매칭).
  String get key => switch (this) {
        WidgetDisplayType.photoInfo => 'photo_info',
        WidgetDisplayType.photoOnly => 'photo_only',
        WidgetDisplayType.infoOnly => 'info_only',
      };

  static WidgetDisplayType fromKey(String? key) => switch (key) {
        'photo_only' => WidgetDisplayType.photoOnly,
        'info_only' => WidgetDisplayType.infoOnly,
        _ => WidgetDisplayType.photoInfo,
      };
}

/// 위젯 설정 영속화 + 네이티브 위젯 즉시 갱신 브리지.
///
/// ## 저장 키 (SharedPreferences, shared_preferences 패키지 내부적으로 `flutter.` 접두사 추가)
/// - `widget_display_type`    : [WidgetDisplayType.key]
/// - `is_widget_setup_done`   : bool, 최초 실행 설정 완료 여부
///
/// ## 네이티브 연동
/// 값이 바뀌면 `com.snappark/widget` MethodChannel의 `refreshWidget` 을 호출해
/// 설치된 모든 AppWidgetProvider 가 새 설정으로 즉시 다시 그려지게 한다.
class WidgetSettingsService {
  static const _typeKey = 'widget_display_type';
  static const _setupDoneKey = 'is_widget_setup_done';
  static const _colorKey = 'widget_info_bg_color';
  static const _channel = MethodChannel('com.snappark/widget');

  static Future<WidgetDisplayType> getType() async {
    final prefs = await SharedPreferences.getInstance();
    return WidgetDisplayType.fromKey(prefs.getString(_typeKey));
  }

  /// 타입을 저장하고 네이티브 위젯을 즉시 갱신한다.
  static Future<void> setType(WidgetDisplayType type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_typeKey, type.key);
    await _refreshWidgets();
  }

  /// 위치전용 모드 배경색 (#RRGGBB hex) 를 반환한다. 기본값: Toss Blue.
  static Future<String> getInfoColor() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_colorKey) ?? '#0064FF';
  }

  /// 위치전용 모드 배경색을 저장하고 네이티브 위젯을 즉시 갱신한다.
  static Future<void> setInfoColor(String hex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_colorKey, hex);
    await _refreshWidgets();
  }

  static Future<bool> isSetupDone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_setupDoneKey) ?? false;
  }

  static Future<void> markSetupDone() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_setupDoneKey, true);
  }

  /// 네이티브 위젯을 즉시 다시 그리도록 요청 (best-effort).
  static Future<void> _refreshWidgets() async {
    try {
      await _channel.invokeMethod<void>('refreshWidget');
    } catch (e) {
      debugPrint('[WidgetSettingsService] refreshWidget 실패: $e');
    }
  }

  /// 앱을 백그라운드로 내려 홈 화면이 보이게 한다.
  ///
  /// 위젯 pin 요청(`requestPinAppWidget`) 이후 호출하면, 사용자가 홈 화면 위에
  /// 뜨는 시스템 "홈 화면에 추가" 다이얼로그를 확인하거나, 추가된 위젯을 직접
  /// 드래그해서 원하는 위치로 옮길 수 있다.
  static Future<void> moveAppToBackground() async {
    try {
      await _channel.invokeMethod<void>('moveAppToBackground');
    } catch (e) {
      debugPrint('[WidgetSettingsService] moveAppToBackground 실패: $e');
    }
  }

  /// OS 런처에 "홈 화면에 위젯 고정" 프롬프트를 요청한다 (Android 8.0+).
  ///
  /// [style] 이 주어지면 Kotlin 쪽에서 해당 스타일을 반영한 RemoteViews 프리뷰를
  /// `AppWidgetManager.EXTRA_APPWIDGET_PREVIEW` 로 런처에 전달한다. 이렇게 해야
  /// Samsung One UI 등에서 "추가하기" 프롬프트의 프리뷰가 앱 내 샘플과 동일한
  /// 데이터/스타일로 보여서 UX 가 통일된다.
  ///
  /// ## 결과
  /// - [PinWidgetResult.requested]   : 프롬프트가 표시됨 (사용자 수락/거부는 별개)
  /// - [PinWidgetResult.unsupported] : Android 7 이하이거나 현재 런처 미지원
  /// - [PinWidgetResult.error]       : 예외 발생
  static Future<PinWidgetResult> pinWidget(
    WidgetSize size, {
    WidgetDisplayType? style,
  }) async {
    try {
      final outcome = await _channel.invokeMethod<String>(
        'pinWidget',
        {
          'size': size.key,
          if (style != null) 'style': style.key,
        },
      );
      return switch (outcome) {
        'requested' => PinWidgetResult.requested,
        'unsupported' => PinWidgetResult.unsupported,
        _ => PinWidgetResult.error,
      };
    } catch (e) {
      debugPrint('[WidgetSettingsService] pinWidget 실패: $e');
      return PinWidgetResult.error;
    }
  }
}

/// 고정 요청 대상 위젯 사이즈.
enum WidgetSize {
  size2x1,
  size2x2,
  size4x2,
  size4x4;

  /// Kotlin `MainActivity.requestPinWidget(size)` 의 size 인자와 매칭되는 키.
  String get key => switch (this) {
        WidgetSize.size2x1 => '2x1',
        WidgetSize.size2x2 => '2x2',
        WidgetSize.size4x2 => '4x2',
        WidgetSize.size4x4 => '4x4',
      };

  /// UI 표기용 라벨.
  String get label => switch (this) {
        WidgetSize.size2x1 => '2×1',
        WidgetSize.size2x2 => '2×2',
        WidgetSize.size4x2 => '4×2',
        WidgetSize.size4x4 => '4×4',
      };
}

/// `requestPinAppWidget` 결과 상태.
enum PinWidgetResult { requested, unsupported, error }
