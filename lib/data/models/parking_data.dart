import 'package:freezed_annotation/freezed_annotation.dart';

part 'parking_data.freezed.dart';
part 'parking_data.g.dart';

/// 주차 위치 데이터 모델.
/// SharedPreferences에 JSON String으로 직렬화되어 저장되며,
/// Android Native(AppWidgetProvider)와 동일한 키로 공유된다.
@freezed
class ParkingData with _$ParkingData {
  const factory ParkingData({
    /// 주차 층수 (예: "B2", "3F")
    required String floor,

    /// 주차 구역 (예: "A-04", "나-12")
    required String zone,

    /// 촬영된 사진 로컬 경로 (없으면 null)
    String? photoPath,

    /// 저장 시각 (ISO 8601 문자열로 직렬화)
    required DateTime timestamp,
  }) = _ParkingData;

  factory ParkingData.fromJson(Map<String, dynamic> json) =>
      _$ParkingDataFromJson(json);
}
