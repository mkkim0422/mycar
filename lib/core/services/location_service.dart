import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// 촬영 시점 1회 조회용 위치 스냅샷.
///
/// 모든 필드는 null 가능 — 권한 거부/타임아웃/에뮬레이터 Geocoder 미지원 등
/// 어떤 실패 상황에서도 호출 측이 저장 흐름을 이어갈 수 있도록 설계됨.
class LocationSnapshot {
  final double? latitude;
  final double? longitude;
  final String? address;

  const LocationSnapshot({this.latitude, this.longitude, this.address});

  static const empty = LocationSnapshot();

  bool get hasCoords => latitude != null && longitude != null;
}

/// 전경(foreground) 1회 위치 조회 서비스.
///
/// ## 정확도 수렴 전략 (스트림 기반 샘플링)
/// 단발 `getCurrentPosition` 호출은 GPS cold-start 시 Fused 가 우선 반환하는
/// **셀룰러·WiFi 기반 coarse 위치**(정확도 100~500m) 를 그대로 반환해
/// "주소가 실제 촬영 위치와 다름" 문제가 생긴다.
///
/// 이 클래스는 **PositionStream 을 짧게 구독**하여 Geolocator 가 내놓는 여러
/// fix 중 가장 정확한 것을 채택한다:
/// 1. [_accuracyWindow] 6초 동안 스트림 구독
/// 2. 매 fix 마다 `accuracy` 값이 더 작은(= 더 정확한) 것을 best 로 갱신
/// 3. `accuracy <= _targetAccuracyMeters` (15m) 도달 시 **즉시 종료**
/// 4. 윈도우 만료 시에도 가장 좋은 샘플 반환
///
/// ## 설계 원칙
/// - 어떤 실패도 throw하지 않는다 → 촬영 흐름이 위치 때문에 막히면 안 됨
/// - 지연은 사용자 체감에 영향 없음 — 촬영 직후 바탕 Future 로 동작하며
///   사용자가 층·구역 입력하는 동안 정확도가 수렴
/// - 역지오코딩 실패는 좌표 자체에 영향 없음 (좌표만 유지)
class LocationService {
  /// GPS 정확도 수렴을 위한 스트림 구독 최대 시간.
  /// 사전 워밍업으로 시작 타이밍이 당겨지므로 6초로 충분히 수렴 여유를 준다.
  static const _accuracyWindow = Duration(seconds: 6);

  /// 이 정확도(meter) 에 도달하면 조기 반환. 20m 이하면 한국 도로명+번지
  /// (이면도로 포함) 역지오코딩이 실제 도로로 매칭되는 경계.
  /// 30m 를 허용하면 사성로75번길 ↔ 광일로 처럼 인접 도로가 혼동될 수 있다.
  static const double _targetAccuracyMeters = 20;

  /// lastKnownPosition 즉시 수용 기준.
  /// - 1분 이내 (그 이상이면 차량 이동 가능성)
  /// - 30m 이내 (한국 이면도로 매칭 안정권. 50m 넘으면 옆 도로로 혼동)
  /// 기존 200m/2분 은 "건물 블록 단위"엔 맞지만 "도로명 단위"에선 잘못된 이웃
  /// 도로를 반환할 수 있어 기각됐다. (예: 사성로75번길→광일로 오류)
  static const _cachedFixMaxAge = Duration(minutes: 1);
  static const double _cachedFixMaxAccuracy = 30;

  /// 현재 위치와 한국어 주소를 조회한다. 실패 시 [LocationSnapshot.empty].
  ///
  /// [prewarm] 이 true 면 권한이 아직 없을 때 프롬프트를 띄우지 않고 즉시 empty
  /// 를 반환한다. 카메라 화면 진입 직후 사전 워밍업에 사용 — 사용자가 촬영
  /// 버튼을 눌렀을 때 비로소 권한 다이얼로그가 뜨도록 한다.
  static Future<LocationSnapshot> fetchCurrent({bool prewarm = false}) async {
    try {
      // 1) 권한 체크. prewarm 모드에서는 요청하지 않고 즉시 empty.
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        if (prewarm) return LocationSnapshot.empty;
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return LocationSnapshot.empty;
      }

      // 2) 위치 서비스 활성화 확인
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return LocationSnapshot.empty;

      // 3) 위치 획득 — lastKnown 이 충분히 신선하면 즉시 사용, 아니면 스트림 수렴.
      final position = await _acquirePosition();
      if (position == null) return LocationSnapshot.empty;

      debugPrint(
          '[LocationService] fix: (${position.latitude}, ${position.longitude}) '
          '± ${position.accuracy.toStringAsFixed(1)}m');

      // 4) 역지오코딩 (실패해도 좌표는 유지)
      final address = await _reverseGeocode(
        position.latitude,
        position.longitude,
      );

      return LocationSnapshot(
        latitude: position.latitude,
        longitude: position.longitude,
        address: address,
      );
    } catch (e) {
      debugPrint('[LocationService] 위치 조회 실패: $e');
      return LocationSnapshot.empty;
    }
  }

  /// 위치를 가능한 빨리 획득한다.
  ///
  /// ## 전략 (네이티브 카메라 앱과 동일한 패턴)
  /// 1. **lastKnownPosition 즉시 조회** — OS Fused 가 유지하는 캐시 fix.
  ///    2분 이내 & 200m 이내면 **그대로 반환** (대기 0초). 대부분의 경우 여기서 종료.
  /// 2. 캐시가 없거나 너무 오래됐으면 **포지션 스트림으로 신규 fix 수렴**.
  ///    - lastKnown 을 seed 로 시작해 더 정확한 fix 가 도착하면 교체.
  ///    - 30m 달성 시 조기 종료, 아니면 4초 윈도우 만료 시 best 반환.
  /// 3. 스트림도 실패하면 신선도 무관하게 lastKnown 폴백.
  static Future<Position?> _acquirePosition() async {
    // 1) lastKnown 즉시 조회
    Position? lastKnown;
    try {
      lastKnown = await Geolocator.getLastKnownPosition();
    } catch (_) {}

    // 캐시가 충분히 신선하고 정확하면 즉시 반환 — 네이티브 카메라 속도
    if (lastKnown != null && _isCacheFixUsable(lastKnown)) {
      return lastKnown;
    }

    // 2) 스트림 기반 수렴, lastKnown 을 seed 로 사용
    Position? best = lastKnown;
    final completer = Completer<Position?>();
    late StreamSubscription<Position> sub;
    Timer? windowTimer;

    void finish() {
      if (completer.isCompleted) return;
      windowTimer?.cancel();
      completer.complete(best);
    }

    try {
      sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        ),
      ).listen(
        (pos) {
          if (best == null || pos.accuracy < best!.accuracy) best = pos;
          if (pos.accuracy <= _targetAccuracyMeters) finish();
        },
        onError: (e) {
          debugPrint('[LocationService] position stream error: $e');
          finish();
        },
        cancelOnError: false,
      );

      windowTimer = Timer(_accuracyWindow, finish);

      final result = await completer.future;
      await sub.cancel();
      // 스트림이 빈손이면 신선도 무관 lastKnown 폴백
      return result ?? lastKnown;
    } catch (e) {
      debugPrint('[LocationService] _acquirePosition 예외: $e');
      return lastKnown;
    }
  }

  /// lastKnownPosition 의 신선도·정확도가 즉시 사용 가능한 수준인지.
  static bool _isCacheFixUsable(Position p) {
    if (p.accuracy <= 0 || p.accuracy > _cachedFixMaxAccuracy) return false;
    final age = DateTime.now().difference(p.timestamp);
    return !age.isNegative && age < _cachedFixMaxAge;
  }

  /// 좌표 → 한국어 주소. 실패 시 null.
  ///
  /// ## 우선순위 체인 (정확도 순)
  /// 1. **Kakao Local API** — 한국 정부 도로명주소 DB 직결, 이면도로·번지 완벽 매칭
  /// 2. **Nominatim (OpenStreetMap)** — 국제 무료 서비스, 한국 이면도로는 커버 미흡
  /// 3. Android 네이티브 Geocoder — 오프라인/네트워크 실패 시 폴백
  ///
  /// Kakao 가 설정돼 있으면 그것만 사용(가장 정확). 실패 시 OSM→Android 순 폴백.
  /// Kakao 미설정 시에는 OSM 과 Android 를 **병렬** 실행해 체감 지연을 줄인다.
  ///
  /// Android Geocoder 단독 사용은 Google POI DB 가 도로명보다 아파트 단지명을
  /// 우선시하는 구조라 "철산주공 10단지아파트" 같은 잡음 결과를 반복 생성한다.
  static Future<String?> _reverseGeocode(double lat, double lng) async {
    // 1순위: Kakao (설정돼 있을 때만)
    if (AppConfig.isKakaoLocalApiConfigured) {
      final fromKakao = await _reverseGeocodeKakao(lat, lng);
      if (fromKakao != null && fromKakao.isNotEmpty) return fromKakao;
    }

    // 2·3순위: Nominatim + Android 병렬, OSM 우선 수거
    final osmFuture = _reverseGeocodeNominatim(lat, lng);
    final androidFuture = _reverseGeocodeAndroid(lat, lng);

    final fromOsm = await osmFuture;
    if (fromOsm != null && fromOsm.isNotEmpty) return fromOsm;
    return await androidFuture;
  }

  /// Kakao Local API 좌표→주소 변환.
  ///
  /// ## API
  /// - Endpoint : `https://dapi.kakao.com/v2/local/geo/coord2address.json`
  /// - Auth     : `Authorization: KakaoAK {REST_API_KEY}` 헤더
  /// - Params   : `x={경도} y={위도}` (주의: x=lng, y=lat 순서)
  ///
  /// ## 응답 구조 요약
  /// ```json
  /// { "documents": [{
  ///   "road_address": { "address_name": "경기도 수원시 영통구 사성로75번길 1", ... },
  ///   "address":      { "address_name": "경기도 수원시 영통구 매탄동 123-4",   ... }
  /// }]}
  /// ```
  /// 도로명주소(`road_address`) 를 우선 채택하고, 없으면 지번주소(`address`) 사용.
  /// 두 주소 모두 한국 행안부 도로명주소 체계 그대로라 이면도로·번지까지 정확하다.
  static Future<String?> _reverseGeocodeKakao(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://dapi.kakao.com/v2/local/geo/coord2address.json'
        '?x=$lng&y=$lat',
      );
      final res = await http.get(
        uri,
        headers: {
          'Authorization': 'KakaoAK ${AppConfig.kakaoRestApiKey}',
        },
      ).timeout(const Duration(seconds: 3));

      if (res.statusCode != 200) {
        debugPrint('[LocationService] Kakao ${res.statusCode}: ${res.body}');
        return null;
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map<String, dynamic>) return null;
      final docs = body['documents'];
      if (docs is! List || docs.isEmpty) return null;
      final doc = docs.first;
      if (doc is! Map<String, dynamic>) return null;

      // 도로명주소 우선
      final road = doc['road_address'];
      if (road is Map<String, dynamic>) {
        final name = road['address_name'];
        if (name is String && name.trim().isNotEmpty) return name.trim();
      }
      // 지번주소 폴백
      final jibun = doc['address'];
      if (jibun is Map<String, dynamic>) {
        final name = jibun['address_name'];
        if (name is String && name.trim().isNotEmpty) return name.trim();
      }
      return null;
    } catch (e) {
      debugPrint('[LocationService] Kakao 실패: $e');
      return null;
    }
  }

  /// OpenStreetMap Nominatim 역지오코딩.
  ///
  /// ## API
  /// - Endpoint : `https://nominatim.openstreetmap.org/reverse`
  /// - Auth     : 키 불필요 (공개 무료 서비스)
  /// - Locale   : `accept-language=ko` 로 한국어 결과 강제
  /// - Zoom 18  : 건물 단위 정확도 (도로명 + 번지까지)
  ///
  /// ## Usage Policy 준수 사항
  /// - User-Agent 필수 (앱 식별자) — 미설정 시 403 반환
  /// - 초당 1회 이하 (사진 촬영 빈도라 자연 만족)
  /// - Bulk geocoding 금지 (앱은 촬영당 1회 호출이라 무관)
  /// 출처: https://operations.osmfoundation.org/policies/nominatim/
  ///
  /// ## 한국 주소 정확도
  /// 도시/광역시는 도로명·번지가 거의 100% 매칭. 아파트 단지명 대신 실제
  /// 도로명("사성로75번길")을 반환한다는 점이 Google Geocoder 와의 결정적 차이.
  static Future<String?> _reverseGeocodeNominatim(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=$lat&lon=$lng&accept-language=ko&zoom=18&addressdetails=1',
      );
      final res = await http.get(
        uri,
        headers: const {
          // User-Agent 누락 시 Nominatim 이 403 으로 거절한다.
          'User-Agent': 'SnapPark/2.0 (com.snappark; help@sphinfo.co.kr)',
        },
      ).timeout(const Duration(seconds: 3));

      if (res.statusCode != 200) {
        debugPrint('[LocationService] Nominatim ${res.statusCode}');
        return null;
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map<String, dynamic>) return null;
      final addr = body['address'];
      if (addr is! Map<String, dynamic>) return null;

      return _formatNominatimAddress(addr);
    } catch (e) {
      debugPrint('[LocationService] Nominatim 실패: $e');
      return null;
    }
  }

  /// Nominatim `address` 객체를 "<시/구> <동> <도로명> <번지>" 형태로 합성.
  ///
  /// Nominatim 의 한국 주소 키 매핑 (관찰된 경향):
  ///   borough        : 서울 안의 "강남구" 같은 자치구
  ///   city_district  : borough 의 별칭으로 들어오는 경우
  ///   city           : "광명시", "수원시" 같은 시 단위
  ///   town/county    : 군 단위 또는 일부 읍면 구역
  ///   suburb         : "철산동", "역삼동" 같은 행정동
  ///   neighbourhood  : suburb 의 보조 키
  ///   road           : "사성로75번길", "테헤란로" 도로명
  ///   house_number   : "1", "123-45" 건물번호
  static String? _formatNominatimAddress(Map<String, dynamic> addr) {
    String? pick(List<String> keys) {
      for (final k in keys) {
        final v = addr[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return null;
    }

    // 가장 세부적인 시·군·구 단위 우선 (서울이면 borough="강남구",
    // 광명/수원 등은 city="광명시"). state(경기도/서울특별시) 는 중복이라 제외.
    final city = pick(['borough', 'city_district', 'city', 'town', 'county']);
    final dong = pick(['suburb', 'neighbourhood', 'quarter', 'village', 'hamlet']);
    final road = pick(['road']);
    final bldgNo = pick(['house_number']);

    final parts = <String>[];
    final seen = <String>{};
    for (final piece in [city, dong, road, bldgNo]) {
      if (piece == null || piece.isEmpty) continue;
      if (seen.contains(piece)) continue;
      // 중첩 포함 방지: 이미 추가된 토큰이 이 piece 를 포함하거나 그 반대면 스킵.
      if (seen.any((e) => e.contains(piece) || piece.contains(e))) continue;
      seen.add(piece);
      parts.add(piece);
    }

    if (parts.isEmpty) return null;
    return parts.join(' ');
  }

  /// 폴백: Android 네이티브 Geocoder 기반 역지오코딩.
  ///
  /// 기존 구현 유지 — Nominatim 호출이 네트워크 오류/타임아웃으로 실패한
  /// 경우에만 사용된다. POI 오염이 있을 수 있어 1순위가 아닌 안전망 역할.
  static Future<String?> _reverseGeocodeAndroid(double lat, double lng) async {
    try {
      await setLocaleIdentifier('ko_KR');
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isEmpty) return null;

      String? bestRoad;
      int bestRoadScore = 0;
      String? bestFallback;
      int bestFallbackScore = 0;

      for (final p in placemarks) {
        final formatted = _formatKoreanAddress(p);
        if (formatted == null) continue;
        final tokenCount = formatted.split(RegExp(r'\s+')).length;

        final isRoad = _looksLikeRoadName(p.thoroughfare);

        if (isRoad && tokenCount > bestRoadScore) {
          bestRoad = formatted;
          bestRoadScore = tokenCount;
        }
        if (tokenCount > bestFallbackScore) {
          bestFallback = formatted;
          bestFallbackScore = tokenCount;
        }
      }

      return bestRoad ?? bestFallback;
    } catch (e) {
      debugPrint('[LocationService] Android Geocoder 실패: $e');
      return null;
    }
  }

  /// thoroughfare 값이 "한국 도로명" 형태인지 판별한다.
  ///
  /// - 도로명: "XX로", "XX대로", "XX길" 패턴 → true
  /// - POI 이름(아파트/단지/빌딩/타워 등) → false (도로명이 아님)
  /// - null/빈 값 → false
  static bool _looksLikeRoadName(String? thoroughfare) {
    if (thoroughfare == null) return false;
    final t = thoroughfare.trim();
    if (t.isEmpty) return false;
    // POI 마커가 섞여 있으면 즉시 거절 (예: "철산주공 10단지아파트")
    if (_containsPoiMarker(t)) return false;
    // 도로명 특성: "로" 또는 "길" 을 포함
    return t.contains('로') || t.contains('길');
  }

  /// subLocality 값에서 순수 행정동 이름 토큰만 추출한다.
  ///
  /// Geocoder 가 단일 필드에 지번/POI 를 concat 해 보내는 케이스 대응:
  ///   "철산동1003"                       → "철산동"
  ///   "철산동 70-1번지"                  → "철산동"
  ///   "철산동1003 철산주공 10단지아파트" → "철산동"   (POI 토큰 절단)
  ///   "철산주공 10단지아파트"            → null      (행정동 어미 없음)
  ///
  /// 동/읍/면/리 로 끝나는 첫 토큰을 채택하고 trailing 지번은 제거한다.
  /// 행정동 어미를 가진 토큰이 없으면 dong 정보를 신뢰할 수 없다고 보고 null.
  static String? _extractDong(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    for (final token in trimmed.split(RegExp(r'\s+'))) {
      if (RegExp(r'(?:동|읍|면|리)\d*$').hasMatch(token)) {
        return _stripTrailingLotNumber(token);
      }
    }
    return null;
  }

  /// 한국어 문자 뒤에 붙어있는 trailing 숫자/번지 표기를 제거한다.
  ///
  /// 일부 Android Geocoder 가 subLocality 필드에 지번을 concat 해서 보낸다:
  ///   "철산동1003"  → "철산동"
  ///   "역삼동 123-45" → "역삼동"
  ///   "영등포동1가"  → "영등포동1가"  (한글로 끝나 미매치 → 유지)
  ///   "1동"         → "1동"        (한글 뒤 숫자 아님 → 유지)
  static String? _stripTrailingLotNumber(String? value) {
    if (value == null) return null;
    var t = value.trim();
    if (t.isEmpty) return null;
    t = t.replaceAll(
        RegExp(r'(?<=[가-힣])\s*\d+(?:-\d+)?(?:번지)?\s*$'),
        '').trim();
    return t.isEmpty ? null : t;
  }

  /// 주소 값에 POI(장소명) 성격의 키워드가 포함되어 있는지.
  ///
  /// POI 가 섞이면 "철산동1003 철산주공 10단지아파트" 같은 잡음 주소가 되므로
  /// _formatKoreanAddress 에서 도로명 필드를 null 화하는 가드로도 쓴다.
  static bool _containsPoiMarker(String value) {
    const markers = [
      '아파트', '단지', '빌라', '맨션',
      '빌딩', '타워', '플레이스', '오피스텔',
      '상가', '프라자', '센터',
    ];
    for (final m in markers) {
      if (value.contains(m)) return true;
    }
    return false;
  }

  /// 단일 Placemark 를 한국 주소 포맷 문자열로 변환한다.
  ///
  /// ## 출력 포맷 (3단계 요약)
  ///   "<시·군·구> <동/읍/면> <도로명 또는 번지>"
  ///   예: "광명시 철산동 69-30번지"
  ///       "강남구 역삼동 테헤란로 123"
  ///
  /// ## 의도적으로 생략되는 정보
  /// - 상위 행정구역(경기도/서울특별시 등) — 시·군·구 하나로 충분히 식별 가능
  /// - 국가명(대한민국)·ISO 코드(KR) — 국내 앱에서 불필요
  /// - 건물 내부 층수(1층) — 주차 위치 표시에 불필요하며 Geocoder 가 간헐적으로
  ///   `thoroughfare` 끝에 붙이는 잡음임
  static String? _formatKoreanAddress(Placemark p) {
    // 1) 시·군·구 — locality 우선, 없으면 subAdmin → admin 순.
    //    (locality 가 "광명시"/"강남구" 를 담는 경우가 일반적이며,
    //     상위 "경기도/서울특별시" 는 중복 정보라 건너뛴다.)
    final city = _firstClean([
      p.locality,
      p.subAdministrativeArea,
      p.administrativeArea,
    ]);

    // 2) 동·읍·면 — Geocoder 가 한 필드에 지번/POI 까지 concat 해 내려보내는
    //    경우가 있어 토큰 단위로 분해해 행정동 이름만 추출한다.
    //    예: "철산동1003 철산주공 10단지아파트" → "철산동"
    final dong = _extractDong(p.subLocality);

    // 3) 도로명/번지 + 건물번호.
    //    POI(아파트·단지·빌딩 등) 이름이 섞이면 사용자에게 혼란을 주므로 제거한다.
    //    예: thoroughfare="철산주공 10단지아파트" → road=null → 결과는 시·동까지만.
    var road = _firstClean([p.thoroughfare]);
    if (road != null && _containsPoiMarker(road)) road = null;
    final bldgNo = road == null ? null : _firstClean([p.subThoroughfare]);

    // 중복 및 부분 포함 제거 — 예: city="광명시" 이고 dong 에도 "광명시" 가
    // 들어가 있으면 dong 에서 제거한다. (일부 Android Geocoder 가 dong 필드에
    // 상위 행정구역을 덧붙여 보내는 케이스 방어)
    final parts = <String>[];
    final seen = <String>{};
    for (final piece in [city, dong, road, bldgNo]) {
      if (piece == null || piece.isEmpty) continue;
      if (seen.contains(piece)) continue;
      // 이미 추가된 토큰을 완전히 포함하는 문자열이 없고(역포함 방지),
      // 반대로 이 piece 가 기존 토큰을 포함하지도 않을 때만 추가.
      if (seen.any((e) => e.contains(piece) || piece.contains(e))) continue;
      seen.add(piece);
      parts.add(piece);
    }

    if (parts.isEmpty) return null;
    return parts.join(' ');
  }

  /// 후보 문자열 리스트에서 앞쪽부터 정제(국가/층수 제거) 후 유효한 첫 값을 반환.
  static String? _firstClean(List<String?> candidates) {
    for (final c in candidates) {
      final cleaned = _cleanToken(c);
      if (cleaned != null && cleaned.isNotEmpty) return cleaned;
    }
    return null;
  }

  /// 필드값에서 국가 키워드와 층수 접미어를 제거한다.
  ///
  /// - 국가: "대한민국", "Korea", "Republic of Korea", "KR" 등
  /// - 층수: "1층", "12F", "지하 2층" 같은 건물 내부 표기
  static String? _cleanToken(String? raw) {
    if (raw == null) return null;
    var t = raw.trim();
    if (t.isEmpty) return null;

    // 국가 키워드 제거 (대소문자 무관)
    const countryKeywords = [
      '대한민국',
      'Republic of Korea',
      'South Korea',
      'Korea',
      'KR',
    ];
    for (final kw in countryKeywords) {
      t = t.replaceAll(RegExp(RegExp.escape(kw), caseSensitive: false), '');
    }

    // 층수 접미어 제거: "...69-30번지 1층" → "...69-30번지"
    //   한국어 층수:  "1층", "지하 2층", "B1층"
    //   영문 층수 :   "1F", "12F"
    t = t.replaceAll(
        RegExp(r'\s*(?:지하\s*)?[A-Za-z]?\d+\s*(?:층|F)\b', caseSensitive: false),
        '');

    // 공백/구두점 정리
    t = t.replaceAll(RegExp(r'[,\s]+'), ' ').trim();
    return t.isEmpty ? null : t;
  }
}
