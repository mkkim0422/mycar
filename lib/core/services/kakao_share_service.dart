import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../theme/app_theme.dart';
import '../../data/models/parking_data.dart';

/// 주차 위치 공유 서비스.
///
/// 원본 사진 하단에 캡션 바(메인 텍스트 + "by 주차기억")를 합성한 한 장의 PNG 를
/// 만들어 OS 공유 시트(`Intent.ACTION_SEND`)로 전송한다. 카카오톡이 외부 앱의
/// 텍스트를 무시하는 이슈를 사진 자체에 텍스트를 그려 회피한다.
///
/// 클래스 이름은 호출부 호환을 위해 유지(`KakaoShareService`).
class KakaoShareService {
  KakaoShareService._();

  static const _brandTag = '주차기억';

  /// [data]를 OS 공유 시트로 공유한다.
  ///
  /// 사진이 있으면 캡션을 합성한 PNG 를, 합성 실패·사진 없음이면 텍스트만 전송한다.
  static Future<void> share(BuildContext context, ParkingData data) async {
    try {
      final caption = _buildDescription(data);
      final photoPath = data.photoPath;
      final hasPhoto = photoPath != null && File(photoPath).existsSync();

      String? composedPath;
      if (hasPhoto) {
        composedPath = await _composeCaptionedImage(
          sourcePath: photoPath,
          caption: caption,
        );
      }

      final params = composedPath != null
          ? ShareParams(files: [XFile(composedPath)])
          : ShareParams(text: caption);

      await SharePlus.instance.share(params);
    } catch (_) {
      _showSnackBar(context, '공유에 실패했습니다. 잠시 후 다시 시도해주세요.');
    }
  }

  /// 원본 사진 하단에 iOS 글래스모피즘 카드를 오버레이한 PNG 를 임시 디렉토리에
  /// 저장하고 경로를 반환한다. 사진은 잘리거나 줄어들지 않고 원본 비율 그대로
  /// 보존된다.
  ///
  /// 합성 단계:
  /// 1. 사진 그대로 그리기
  /// 2. 카드 영역만 clipRRect → saveLayer(blur) 안에서 사진 재그리기 → 블러 효과
  /// 3. 어두운 톤 오버레이로 가독성 확보 + 글래스 깊이감
  /// 4. 살짝 흰색 보더로 글래스 가장자리 표현
  /// 5. 흰색 메인 텍스트 + 반투명 흰색 브랜드 워터마크
  ///
  /// 디코드/인코드 실패 시 null 을 반환하여 호출부에서 텍스트 폴백을 쓰도록 한다.
  static Future<String?> _composeCaptionedImage({
    required String sourcePath,
    required String caption,
  }) async {
    ui.Image? src;
    ui.Image? composed;
    try {
      final bytes = await File(sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      src = frame.image;

      final w = src.width.toDouble();
      final h = src.height.toDouble();

      // ── 글래스 카드 메트릭 (모두 사진 너비 비례) ────────────────────────
      final sideMargin = w * 0.05;
      final bottomMargin = w * 0.05;
      final paddingH = w * 0.05;
      final paddingV = w * 0.045;
      final cornerRadius = w * 0.04;
      final innerWidth = w - sideMargin * 2 - paddingH * 2;

      // ── 텍스트 사이즈 측정 (카드 높이 계산에 필요) ──────────────────────
      final mainFontSize = w * 0.052;
      final brandFontSize = w * 0.028;
      const textGap = 8.0;

      final mainPara = (ui.ParagraphBuilder(ui.ParagraphStyle(
        textAlign: TextAlign.center,
        fontSize: mainFontSize,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ))
            ..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF)))
            ..addText(caption))
          .build()
        ..layout(ui.ParagraphConstraints(width: innerWidth));

      final brandPara = (ui.ParagraphBuilder(ui.ParagraphStyle(
        textAlign: TextAlign.center,
        fontSize: brandFontSize,
        fontWeight: FontWeight.w500,
        height: 1.2,
      ))
            ..pushStyle(ui.TextStyle(color: const Color(0xB3FFFFFF)))
            ..addText(_brandTag))
          .build()
        ..layout(ui.ParagraphConstraints(width: innerWidth));

      final cardContentH = mainPara.height + textGap + brandPara.height;
      final cardH = paddingV * 2 + cardContentH;
      final cardRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          sideMargin,
          h - cardH - bottomMargin,
          w - sideMargin * 2,
          cardH,
        ),
        Radius.circular(cornerRadius),
      );

      // ── Canvas 시작 (totalH = h, 사진 원본 비율 그대로) ─────────────────
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

      // 1. 원본 사진
      canvas.drawImage(src, Offset.zero, Paint());

      // 2. 글래스 카드 영역만 블러 + 어두운 톤
      canvas.save();
      canvas.clipRRect(cardRect);

      // saveLayer 에 blur 필터 적용 → 안에서 그리는 모든 것이 블러됨
      final cardBounds = cardRect.outerRect;
      canvas.saveLayer(
        cardBounds,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      );
      canvas.drawImage(src, Offset.zero, Paint());
      canvas.restore(); // blur saveLayer 끝

      // 어두운 톤 오버레이 (검정 40%)
      canvas.drawRRect(
        cardRect,
        Paint()..color = const Color(0x66000000),
      );

      canvas.restore(); // clipRRect 끝

      // 3. 글래스 보더 (살짝 흰색, 가장자리 강조)
      canvas.drawRRect(
        cardRect,
        Paint()
          ..color = const Color(0x40FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (w * 0.0015).clamp(1.0, 4.0),
      );

      // 4. 텍스트
      final textOffsetX = sideMargin + paddingH;
      final textTop = cardRect.top + paddingV;
      canvas.drawParagraph(mainPara, Offset(textOffsetX, textTop));
      canvas.drawParagraph(
        brandPara,
        Offset(textOffsetX, textTop + mainPara.height + textGap),
      );

      // ── PNG 변환 + 임시 파일 저장 ───────────────────────────────────────
      final picture = recorder.endRecording();
      composed = await picture.toImage(w.toInt(), h.toInt());
      picture.dispose();
      final byteData =
          await composed.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;

      final tempDir = await getTemporaryDirectory();
      final filename = 'share_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File('${tempDir.path}/$filename');
      await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      return file.path;
    } catch (_) {
      return null;
    } finally {
      src?.dispose();
      composed?.dispose();
    }
  }

  /// 공유 글 본문 생성. 층/구역 유무에 따라 4가지로 분기한다.
  /// 주소·좌표·지도링크는 의도적으로 미포함.
  /// 입력 화면에서 빈 값일 때 저장되는 placeholder `'-'` 도 빈 값으로 처리.
  static String _buildDescription(ParkingData data) {
    final floor = _normalize(data.floor);
    final zone = _normalize(data.zone);
    if (floor != null && zone != null) {
      return '$floor · $zone에 주차했어요';
    }
    if (floor != null) {
      return '$floor에 주차했어요';
    }
    if (zone != null) {
      return '$zone에 주차했어요';
    }
    return '여기에 주차했어요';
  }

  static String? _normalize(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '-') return null;
    return trimmed;
  }

  static void _showSnackBar(
    BuildContext context,
    String message, {
    Duration? duration,
  }) {
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
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }
}
