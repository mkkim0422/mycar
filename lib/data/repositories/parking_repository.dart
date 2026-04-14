import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/parking_data.dart';

/// SharedPreferences 키 상수.
///
/// Flutter의 shared_preferences 패키지는 내부적으로
/// 'FlutterSharedPreferences' 파일에 'flutter.<key>' 형태로 저장한다.
/// Android Native에서는 동일 파일명 + 'flutter.parking_data' 키로 읽는다.
/// → [SharedPrefsHelper.kt] 참고.
const _kParkingDataKey = 'parking_data';

/// 위젯 갱신 MethodChannel.
/// MainActivity의 "refreshWidget" 핸들러가 등록된 모든 홈 위젯에
/// APPWIDGET_UPDATE 브로드캐스트를 전송하여 실시간 동기화한다.
const _widgetChannel = MethodChannel('com.snappark/widget');

class ParkingRepository {
  /// 주차 데이터를 JSON String으로 직렬화하여 덮어쓰기 저장.
  /// 항상 단일 레코드만 유지한다 (최근 위치 1개).
  /// 저장 완료 후 네이티브 홈 위젯을 즉시 갱신한다.
  Future<void> save(ParkingData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kParkingDataKey, jsonEncode(data.toJson()));
    } catch (e) {
      debugPrint('[ParkingRepository] save() 실패: $e');
      // 저장 실패 시 위젯 갱신도 의미 없으므로 조기 반환
      return;
    }

    // 위젯 실시간 갱신 (best-effort: 채널 미등록·예외 시 무시)
    try {
      await _widgetChannel.invokeMethod<void>('refreshWidget');
    } catch (_) {}
  }

  /// 저장된 주차 데이터를 불러온다.
  /// 저장된 데이터가 없으면 null 반환.
  /// 데이터 오염(JSON 파싱 실패) 시에도 null을 반환하여 크래시를 방지한다.
  Future<ParkingData?> get() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_kParkingDataKey);
      if (jsonString == null) return null;
      return ParkingData.fromJson(
          jsonDecode(jsonString) as Map<String, dynamic>);
    } catch (e) {
      // 저장 데이터 오염(앱 업데이트·직접 수정 등) → 빈 상태로 안전 복귀
      debugPrint('[ParkingRepository] get() 파싱 실패, 빈 상태 반환: $e');
      return null;
    }
  }

  /// 저장된 주차 데이터를 삭제한다.
  /// 삭제 후 네이티브 홈 위젯도 빈 상태로 갱신한다.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kParkingDataKey);
    } catch (e) {
      debugPrint('[ParkingRepository] clear() 실패: $e');
      return;
    }

    // 위젯을 빈 상태로 갱신 (best-effort)
    try {
      await _widgetChannel.invokeMethod<void>('refreshWidget');
    } catch (_) {}
  }
}
