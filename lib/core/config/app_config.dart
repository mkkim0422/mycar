/// SnapPark V2 배포 전 교체 필요 설정 상수.
///
/// ## 출시 체크리스트
/// 1. [kakaoNativeAppKey]
///    - https://developers.kakao.com 로그인
///    - 내 애플리케이션 > 앱 키 > **네이티브 앱 키** 복사
///    - 플랫폼 > Android 등록: 패키지명 `com.snappark`, 마켓 URL 입력
///    - 제품 설정 > 카카오톡 공유 > 활성화 ON
/// 2. [appLandingUrl]
///    - Play Store 출시 후 실제 스토어 URL 또는 공식 홈페이지 URL로 교체
///    - 카카오 공유 카드의 "이동" 링크로 사용된다.
class AppConfig {
  AppConfig._();

  /// 카카오 네이티브 앱 키 (Kakao Developers Console에서 발급).
  static const String kakaoNativeAppKey = 'YOUR_KAKAO_NATIVE_APP_KEY';

  /// 카카오 REST API 키 (좌표→한국 도로명주소 역지오코딩용).
  ///
  /// ## 왜 필요한가
  /// OSM/Nominatim 은 한국 이면도로(예: "사성로75번길") 커버리지가 불완전해
  /// 인접 메인 도로(예: "광일로")로 잘못 매칭되는 경우가 많다. Kakao Local API
  /// 는 한국 정부 도로명주소 DB 를 직접 사용해 번지까지 정확히 반환한다.
  ///
  /// ## 발급 방법
  /// 1. https://developers.kakao.com → 내 애플리케이션 → [앱 키]
  /// 2. **REST API 키** 복사 (네이티브 앱 키와 다른 값)
  /// 3. 플랫폼 > Android 등록 상태면 추가 설정 불필요 (도메인 등록은 웹만)
  ///
  /// 키가 비어 있으면 Nominatim → Android Geocoder 폴백 체인이 사용된다.
  static const String kakaoRestApiKey = 'YOUR_KAKAO_REST_API_KEY';

  /// 카카오 공유 카드 랜딩 URL (Play Store 출시 후 실제 URL로 교체).
  static const String appLandingUrl =
      'https://play.google.com/store/apps/details?id=com.snappark';

  /// 카카오 네이티브 앱 키가 실제 발급 값으로 설정되어 있는지 여부.
  ///
  /// false 이면 카카오 공유 기능(우상단 공유 버튼 등)을 UI 에서 감춰
  /// 플레이스홀더 키로 요청했을 때의 `wrong appKey ... format` 에러를 예방한다.
  static bool get isKakaoConfigured =>
      kakaoNativeAppKey.isNotEmpty &&
      kakaoNativeAppKey != 'YOUR_KAKAO_NATIVE_APP_KEY';

  /// Kakao Local REST API 가 사용 가능한지.
  static bool get isKakaoLocalApiConfigured =>
      kakaoRestApiKey.isNotEmpty &&
      kakaoRestApiKey != 'YOUR_KAKAO_REST_API_KEY';
}
