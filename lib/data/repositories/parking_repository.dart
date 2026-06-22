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
/// 최신 주차 데이터 키 (네이티브 위젯이 읽는 키).
const _kParkingDataKey = 'parking_data';

/// 주차 히스토리 리스트 키 (JSON Array).
const _kParkingHistoryKey = 'parking_history';

/// 위젯 갱신 MethodChannel.
const _widgetChannel = MethodChannel('com.snappark/widget');

class ParkingRepository {
  /// 주차 데이터를 저장한다.
  /// - `parking_data`: 최신 1건 (홈 화면 + 네이티브 위젯용)
  /// - `parking_history`: 전체 히스토리 리스트 (주차기록 보기용)
  Future<void> save(ParkingData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = data.toJson();

      // 히스토리를 parking_data 보다 **먼저** 로드한다. 순서를 바꾸면 첫 저장 시
      // (히스토리 키가 없어) _loadHistory 의 마이그레이션 폴백이 방금 덮어쓴
      // parking_data 를 다시 읽어와, 동일 레코드가 2건 들어가는 버그가 생긴다.
      final history = await _loadHistory(prefs);
      history.insert(0, json);
      if (history.length > 100) history.removeRange(100, history.length);

      await prefs.setString(_kParkingDataKey, jsonEncode(json));
      await prefs.setString(_kParkingHistoryKey, jsonEncode(history));
    } catch (e) {
      debugPrint('[ParkingRepository] save() 실패: $e');
      return;
    }

    try {
      await _widgetChannel.invokeMethod<void>('refreshWidget');
    } catch (e) { debugPrint('[ParkingRepository] 위젯 갱신 실패: $e'); }
  }

  /// 최신 주차 데이터를 반환한다 (홈 화면 표시용).
  Future<ParkingData?> get() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_kParkingDataKey);
      if (jsonString == null) return null;
      return ParkingData.fromJson(
          jsonDecode(jsonString) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[ParkingRepository] get() 파싱 실패: $e');
      return null;
    }
  }

  /// 전체 주차 히스토리를 반환한다 (최신순).
  Future<List<ParkingData>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = await _loadHistory(prefs);
      return history
          .map((e) => ParkingData.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[ParkingRepository] getAll() 실패: $e');
      return [];
    }
  }

  /// 특정 기록의 위치 정보(좌표·주소) 만 업데이트한다.
  ///
  /// ## 사용 시나리오
  /// 카메라 저장 흐름이 GPS 수렴을 기다리지 않고 즉시 끝난 뒤, 백그라운드에서
  /// `LocationService.fetchCurrent()` 가 좌표/주소를 확보하면 이 메서드로 동일
  /// 레코드(timestamp 일치) 의 위치 필드만 갱신한다.
  ///
  /// ## 매칭 규칙
  /// `timestamp` 가 정확히 일치하는 레코드를 찾아 `copyWith` 로 좌표·주소를
  /// 덮어쓴다. `floor`/`zone`/`photoPath` 등 사용자 입력은 보존된다.
  /// 매칭 레코드가 없으면 (이미 삭제됨 등) no-op 으로 조용히 종료한다.
  ///
  /// 갱신 대상이 `parking_data`(최신 1건) 와 동일하면 그 키도 함께 갱신해
  /// 홈 화면·네이티브 위젯이 즉시 새 값으로 보이게 한다.
  Future<void> updateLocation({
    required DateTime timestamp,
    double? latitude,
    double? longitude,
    String? address,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = await _loadHistory(prefs);

      var updatedIndex = -1;
      for (var i = 0; i < history.length; i++) {
        final entry = history[i];
        if (entry is! Map<String, dynamic>) continue;
        final parsed = ParkingData.fromJson(entry);
        if (parsed.timestamp == timestamp) {
          history[i] = parsed
              .copyWith(
                latitude: latitude,
                longitude: longitude,
                address: address,
              )
              .toJson();
          updatedIndex = i;
          break;
        }
      }

      if (updatedIndex < 0) {
        debugPrint(
          '[ParkingRepository] updateLocation: '
          'timestamp ${timestamp.toIso8601String()} not found',
        );
        return;
      }

      await prefs.setString(_kParkingHistoryKey, jsonEncode(history));

      // 최신 레코드(parking_data) 와 동일하면 함께 갱신 — 홈/위젯에 즉시 반영.
      if (updatedIndex == 0) {
        await prefs.setString(_kParkingDataKey, jsonEncode(history.first));
      }
    } catch (e) {
      debugPrint('[ParkingRepository] updateLocation 실패: $e');
      return;
    }

    try {
      await _widgetChannel.invokeMethod<void>('refreshWidget');
    } catch (e) {
      debugPrint('[ParkingRepository] 위젯 갱신 실패: $e');
    }
  }

  /// 특정 인덱스의 기록들을 삭제한다.
  /// 삭제 후 최신 기록을 `parking_data`에 갱신한다.
  Future<void> deleteAt(Set<int> indices) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = await _loadHistory(prefs);

      // 인덱스 역순 삭제 (앞에서 삭제하면 뒤 인덱스가 밀림)
      final sorted = indices.toList()..sort((a, b) => b.compareTo(a));
      for (final i in sorted) {
        if (i >= 0 && i < history.length) history.removeAt(i);
      }

      await prefs.setString(_kParkingHistoryKey, jsonEncode(history));

      // 최신 기록 갱신
      if (history.isNotEmpty) {
        await prefs.setString(_kParkingDataKey, jsonEncode(history.first));
      } else {
        await prefs.remove(_kParkingDataKey);
      }
    } catch (e) {
      debugPrint('[ParkingRepository] deleteAt() 실패: $e');
      return;
    }

    try {
      await _widgetChannel.invokeMethod<void>('refreshWidget');
    } catch (e) { debugPrint('[ParkingRepository] 위젯 갱신 실패: $e'); }
  }

  /// 모든 기록을 삭제한다.
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kParkingDataKey);
      await prefs.remove(_kParkingHistoryKey);
    } catch (e) {
      debugPrint('[ParkingRepository] clear() 실패: $e');
      return;
    }

    try {
      await _widgetChannel.invokeMethod<void>('refreshWidget');
    } catch (e) { debugPrint('[ParkingRepository] 위젯 갱신 실패: $e'); }
  }

  /// SharedPreferences에서 히스토리 JSON 배열을 로드한다.
  Future<List<dynamic>> _loadHistory(SharedPreferences prefs) async {
    final raw = prefs.getString(_kParkingHistoryKey);
    if (raw == null) {
      // 히스토리가 없으면 기존 단일 레코드를 마이그레이션
      final current = prefs.getString(_kParkingDataKey);
      if (current != null) {
        return [jsonDecode(current)];
      }
      return [];
    }
    final decoded = jsonDecode(raw);
    return decoded is List ? decoded : [];
  }
}
