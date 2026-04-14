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

  /// 카카오 공유 카드 랜딩 URL (Play Store 출시 후 실제 URL로 교체).
  static const String appLandingUrl =
      'https://play.google.com/store/apps/details?id=com.snappark';
}
