import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// 네이버 지도 연동 서비스.
///
/// ## 동작 순서
/// 1. `nmap://` URL 스킴으로 네이버 지도 앱 실행 시도
/// 2. 앱 미설치 또는 스킴 핸들러 없음 → `https://map.naver.com` 웹 버전으로 폴백
///
/// ## Android 11+ 가시성
/// `canLaunchUrl(nmap://...)`은 매니페스트 `<queries>`에 `com.nhn.android.nmap`
/// 패키지가 선언되어 있을 때만 `true`를 반환한다. (매니페스트에 이미 추가됨)
class MapService {
  /// 주차 지점을 네이버 지도에서 **정확한 GPS 좌표 핀**으로 연다.
  ///
  /// ## 동작
  /// 1. `nmap://place?lat=...&lng=...` → 네이버 지도 앱에서 해당 좌표에 핀 표시
  /// 2. 앱 미설치 → `https://map.naver.com` 웹 버전 좌표 폴백
  ///
  /// ## 왜 주소 검색이 아닌 좌표인가
  /// `nmap://search?query=주소` 는 해당 주소의 **대표 지점**(도로 중앙 등)을
  /// 보여주므로, 실제 주차한 건물/주차장 위치와 수십~수백m 차이가 난다.
  /// 좌표 기반 핀은 GPS가 기록한 **정확한 위치**를 보여준다.
  static Future<bool> openLocation({
    required double latitude,
    required double longitude,
    String? address,
  }) async {
    // 핀에 표시할 이름 (주소가 있으면 사용, 없으면 기본 텍스트)
    final name = (address != null && address.trim().isNotEmpty)
        ? address.trim()
        : '주차 위치';
    final encodedName = Uri.encodeComponent(name);

    // 1) 네이버 지도 앱 — 좌표 핀 표시
    final appUri = Uri.parse(
      'nmap://place?lat=$latitude&lng=$longitude&name=$encodedName&appname=com.snappark',
    );
    try {
      if (await canLaunchUrl(appUri)) {
        final launched = await launchUrl(
          appUri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) return true;
      }
    } catch (e) {
      debugPrint('[MapService] nmap:// launch 실패, 웹으로 폴백: $e');
    }

    // 2) 웹 버전 폴백 — 좌표 중심 지도
    final webUri = Uri.parse(
      'https://map.naver.com/v5/?c=$longitude,$latitude,15,0,0,0,dh',
    );
    try {
      return await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[MapService] 웹 지도 launch 실패: $e');
      return false;
    }
  }
}
