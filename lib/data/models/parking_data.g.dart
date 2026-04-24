// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'parking_data.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$ParkingDataImpl _$$ParkingDataImplFromJson(Map<String, dynamic> json) =>
    _$ParkingDataImpl(
      floor: json['floor'] as String,
      zone: json['zone'] as String,
      photoPath: json['photoPath'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      address: json['address'] as String?,
    );

Map<String, dynamic> _$$ParkingDataImplToJson(_$ParkingDataImpl instance) =>
    <String, dynamic>{
      'floor': instance.floor,
      'zone': instance.zone,
      'photoPath': instance.photoPath,
      'timestamp': instance.timestamp.toIso8601String(),
      'latitude': instance.latitude,
      'longitude': instance.longitude,
      'address': instance.address,
    };
