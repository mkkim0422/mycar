// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'parking_data.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

ParkingData _$ParkingDataFromJson(Map<String, dynamic> json) {
  return _ParkingData.fromJson(json);
}

/// @nodoc
mixin _$ParkingData {
  /// 주차 층수 (예: "B2", "3F")
  String get floor => throw _privateConstructorUsedError;

  /// 주차 구역 (예: "A-04", "나-12")
  String get zone => throw _privateConstructorUsedError;

  /// 촬영된 사진 로컬 경로 (없으면 null)
  String? get photoPath => throw _privateConstructorUsedError;

  /// 저장 시각 (ISO 8601 문자열로 직렬화)
  DateTime get timestamp => throw _privateConstructorUsedError;

  /// Serializes this ParkingData to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of ParkingData
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $ParkingDataCopyWith<ParkingData> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $ParkingDataCopyWith<$Res> {
  factory $ParkingDataCopyWith(
          ParkingData value, $Res Function(ParkingData) then) =
      _$ParkingDataCopyWithImpl<$Res, ParkingData>;
  @useResult
  $Res call({String floor, String zone, String? photoPath, DateTime timestamp});
}

/// @nodoc
class _$ParkingDataCopyWithImpl<$Res, $Val extends ParkingData>
    implements $ParkingDataCopyWith<$Res> {
  _$ParkingDataCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of ParkingData
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? floor = null,
    Object? zone = null,
    Object? photoPath = freezed,
    Object? timestamp = null,
  }) {
    return _then(_value.copyWith(
      floor: null == floor
          ? _value.floor
          : floor // ignore: cast_nullable_to_non_nullable
              as String,
      zone: null == zone
          ? _value.zone
          : zone // ignore: cast_nullable_to_non_nullable
              as String,
      photoPath: freezed == photoPath
          ? _value.photoPath
          : photoPath // ignore: cast_nullable_to_non_nullable
              as String?,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$ParkingDataImplCopyWith<$Res>
    implements $ParkingDataCopyWith<$Res> {
  factory _$$ParkingDataImplCopyWith(
          _$ParkingDataImpl value, $Res Function(_$ParkingDataImpl) then) =
      __$$ParkingDataImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String floor, String zone, String? photoPath, DateTime timestamp});
}

/// @nodoc
class __$$ParkingDataImplCopyWithImpl<$Res>
    extends _$ParkingDataCopyWithImpl<$Res, _$ParkingDataImpl>
    implements _$$ParkingDataImplCopyWith<$Res> {
  __$$ParkingDataImplCopyWithImpl(
      _$ParkingDataImpl _value, $Res Function(_$ParkingDataImpl) _then)
      : super(_value, _then);

  /// Create a copy of ParkingData
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? floor = null,
    Object? zone = null,
    Object? photoPath = freezed,
    Object? timestamp = null,
  }) {
    return _then(_$ParkingDataImpl(
      floor: null == floor
          ? _value.floor
          : floor // ignore: cast_nullable_to_non_nullable
              as String,
      zone: null == zone
          ? _value.zone
          : zone // ignore: cast_nullable_to_non_nullable
              as String,
      photoPath: freezed == photoPath
          ? _value.photoPath
          : photoPath // ignore: cast_nullable_to_non_nullable
              as String?,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
    ));
  }
}

/// @nodoc
@JsonSerializable()
class _$ParkingDataImpl implements _ParkingData {
  const _$ParkingDataImpl(
      {required this.floor,
      required this.zone,
      this.photoPath,
      required this.timestamp});

  factory _$ParkingDataImpl.fromJson(Map<String, dynamic> json) =>
      _$$ParkingDataImplFromJson(json);

  /// 주차 층수 (예: "B2", "3F")
  @override
  final String floor;

  /// 주차 구역 (예: "A-04", "나-12")
  @override
  final String zone;

  /// 촬영된 사진 로컬 경로 (없으면 null)
  @override
  final String? photoPath;

  /// 저장 시각 (ISO 8601 문자열로 직렬화)
  @override
  final DateTime timestamp;

  @override
  String toString() {
    return 'ParkingData(floor: $floor, zone: $zone, photoPath: $photoPath, timestamp: $timestamp)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$ParkingDataImpl &&
            (identical(other.floor, floor) || other.floor == floor) &&
            (identical(other.zone, zone) || other.zone == zone) &&
            (identical(other.photoPath, photoPath) ||
                other.photoPath == photoPath) &&
            (identical(other.timestamp, timestamp) ||
                other.timestamp == timestamp));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode =>
      Object.hash(runtimeType, floor, zone, photoPath, timestamp);

  /// Create a copy of ParkingData
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$ParkingDataImplCopyWith<_$ParkingDataImpl> get copyWith =>
      __$$ParkingDataImplCopyWithImpl<_$ParkingDataImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$ParkingDataImplToJson(
      this,
    );
  }
}

abstract class _ParkingData implements ParkingData {
  const factory _ParkingData(
      {required final String floor,
      required final String zone,
      final String? photoPath,
      required final DateTime timestamp}) = _$ParkingDataImpl;

  factory _ParkingData.fromJson(Map<String, dynamic> json) =
      _$ParkingDataImpl.fromJson;

  /// 주차 층수 (예: "B2", "3F")
  @override
  String get floor;

  /// 주차 구역 (예: "A-04", "나-12")
  @override
  String get zone;

  /// 촬영된 사진 로컬 경로 (없으면 null)
  @override
  String? get photoPath;

  /// 저장 시각 (ISO 8601 문자열로 직렬화)
  @override
  DateTime get timestamp;

  /// Create a copy of ParkingData
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$ParkingDataImplCopyWith<_$ParkingDataImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
