import 'dart:io';

import 'package:flutter/material.dart';
import 'package:kakao_flutter_sdk_share/kakao_flutter_sdk_share.dart';

import '../config/app_config.dart';
import '../theme/app_theme.dart';
import '../../data/models/parking_data.dart';

/// 카카오톡 주차 위치 공유 서비스.
///
/// ## 공유 우선순위
/// 1. 로컬 사진 → 카카오 이미지 서버 업로드 → [FeedTemplate] (사진 카드)
/// 2. 업로드 실패 또는 사진 없음               → [TextTemplate] (텍스트 폴백)
/// 3. 카카오톡 미설치                          → [WebSharerClient] (브라우저 폴백)
///
/// ## 로컬 전용 앱의 이미지 공유 제약
/// 카카오 FeedTemplate은 공개 https:// URL만 허용한다.
/// 로컬 파일은 `ShareClient.uploadImage()`로 카카오 CDN에 임시 업로드하여 URL을 확보한다.
/// 업로드가 실패해도 앱은 크래시하지 않고 텍스트 전용 공유로 자동 전환한다.
class KakaoShareService {
  KakaoShareService._();

  static const _shareTitle = '내 차 어디? 여기!';

  // 배포 전 AppConfig.appLandingUrl을 실제 스토어 URL로 교체하세요.
  static final _appLink = Link(
    mobileWebUrl: Uri.parse(AppConfig.appLandingUrl),
    webUrl: Uri.parse(AppConfig.appLandingUrl),
  );

  // ── 공개 API ─────────────────────────────────────────────────────────────

  /// [data]를 카카오톡으로 공유한다.
  ///
  /// [context]는 에러·성공 SnackBar 표시에 사용된다.
  static Future<void> share(BuildContext context, ParkingData data) async {
    try {
      final description =
          '[${data.floor} · ${data.zone}] 에 주차되었습니다.';

      // ── 1. 사진 업로드 시도 ──────────────────────────────────────────────
      String? imageUrl;
      final photoPath = data.photoPath;
      if (photoPath != null && File(photoPath).existsSync()) {
        imageUrl = await _tryUploadImage(photoPath);
      }

      // ── 2. 템플릿 선택 ───────────────────────────────────────────────────
      final template = imageUrl != null
          ? _buildFeedTemplate(imageUrl, description)
          : _buildTextTemplate(description, data);

      // ── 3. 카카오톡 or 브라우저로 공유 ──────────────────────────────────
      if (await ShareClient.instance.isKakaoTalkSharingAvailable()) {
        final uri =
            await ShareClient.instance.shareDefault(template: template);
        await ShareClient.instance.launchKakaoTalk(uri);
      } else {
        // 카카오톡 미설치 → 모바일 브라우저 기반 공유
        final uri = await WebSharerClient.instance
            .makeDefaultUrl(template: template);
        await launchBrowserTab(uri, popupOpen: true);
      }
    } on KakaoClientException catch (e) {
      _showSnackBar(context, '카카오 앱 키 설정이 필요합니다: ${e.message}');
    } on KakaoApiException catch (e) {
      _showSnackBar(context, '카카오 서버 오류: ${e.message}');
    } catch (e) {
      _showSnackBar(context, '공유에 실패했습니다. 잠시 후 다시 시도해주세요.');
    }
  }

  // ── 내부 헬퍼 ────────────────────────────────────────────────────────────

  /// 로컬 사진을 카카오 CDN에 업로드하여 공개 URL을 반환한다.
  /// 네트워크 불가, 파일 오류 등 모든 예외는 null 반환으로 흡수한다.
  static Future<String?> _tryUploadImage(String localPath) async {
    try {
      final result = await ShareClient.instance.uploadImage(
        image: File(localPath),
      );
      return result.infos.original.url;
    } catch (_) {
      // 업로드 실패 → TextTemplate 폴백. 앱 크래시 없음.
      return null;
    }
  }

  /// FeedTemplate: 사진 카드 + 제목 + 설명 구조.
  /// 카카오톡에서 썸네일이 있는 공유 카드로 표시된다.
  static FeedTemplate _buildFeedTemplate(
      String imageUrl, String description) {
    return FeedTemplate(
      content: Content(
        title: _shareTitle,
        description: description,
        imageUrl: Uri.parse(imageUrl),
        link: _appLink,
      ),
    );
  }

  /// TextTemplate: 텍스트 전용 폴백.
  /// 사진 업로드 실패 또는 사진이 없을 때 사용한다.
  static TextTemplate _buildTextTemplate(
      String description, ParkingData data) {
    final timestamp = _formatTimestamp(data.timestamp);
    return TextTemplate(
      text: '$_shareTitle\n\n$description\n$timestamp',
      link: _appLink,
    );
  }

  static String _formatTimestamp(DateTime dt) {
    final hour = dt.hour;
    final ampm = hour < 12 ? '오전' : '오후';
    final hour12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}년 ${dt.month}월 ${dt.day}일  $ampm $hour12:$min 주차';
  }

  static void _showSnackBar(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.gray900,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        ),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
    );
  }
}
