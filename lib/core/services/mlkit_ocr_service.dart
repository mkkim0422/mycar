import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// On-device ML Kit Text Recognition 이 반환한 주차 구역 인식 힌트.
///
/// 바텀시트의 층/구역 입력 필드를 **사전 채움**하는 데만 쓰이며, 사용자는
/// 언제든 수동으로 수정할 수 있다. 네트워크·API 키 불필요 (완전 오프라인).
class MlkitOcrResult {
  /// 층 숫자 문자열. 기둥 마커가 "B2" 였다면 "2" 가 담긴다.
  /// 빈 문자열이면 자동 채움 없음 (사용자 수동 입력).
  final String floor;

  /// 구역 번호 문자열. "13", "A-4", "P5" 등. 빈 문자열이면 자동 채움 없음.
  final String zone;

  /// 지하 주차장 여부. OCR 결과가 "B" 로 시작했으면 true.
  final bool isBasement;

  /// 인식 신뢰도. "high" = 매치 발견, "low" = 후보 없음/실패.
  final String confidence;

  const MlkitOcrResult({
    required this.floor,
    required this.zone,
    required this.isBasement,
    required this.confidence,
  });

  /// 실패·타임아웃·매치 없음 등 모든 경우의 공용 빈 결과.
  static const empty = MlkitOcrResult(
    floor: '',
    zone: '',
    isBasement: false,
    confidence: 'low',
  );
}

/// Google ML Kit Text Recognition 을 이용한 **완전 오프라인** 주차 구역 OCR.
///
/// ## 처리 파이프라인
/// 1. ML Kit (Korean script) 로 이미지의 모든 라인·바운딩박스 추출
/// 2. 라인 단위로 **번호판 패턴**(12가3456) 이 보이면 통째로 폐기
/// 3. 남은 라인 텍스트에서 주차 구역 후보 패턴 매칭
///    - B+숫자 (지하층 마커: "B2", "B3")
///    - 영문+숫자 (구역 코드: "A-12", "P5")
///    - 숫자만 (순수 구역 번호: "13", "55")
/// 4. **가장 큰 바운딩박스** 면적 기준으로 최우선 후보 선정
/// 5. 최우선이 B 마커면 → floor/isBasement 에, 아니면 zone 에 담아 반환
///
/// ## 실패 처리
/// ML Kit 내부 오류, 모델 다운로드 실패, 2초 타임아웃 등 어떤 상황에서도
/// [MlkitOcrResult.empty] 를 반환한다. 예외를 throw 하지 않으므로 촬영
/// 흐름을 절대 차단하지 않는다.
class MlkitOcrService {
  MlkitOcrService._();

  /// ML Kit 단일 호출의 최대 허용 시간. 기기 연산이라 보통 200~500ms 내
  /// 완료되지만 저사양 기기/큰 이미지 대비 2초 안전 타임아웃.
  static const _timeout = Duration(seconds: 2);

  // ── 번호판 정규식 (DETECT → DISCARD: 개인정보 보호 + 오매칭 방지) ──────
  // 구형: "12가 3456", "123나 4567"
  // 신형: "12가3456", "서울 12가 3456", "가나 1234"
  static final _licensePlatePatterns = [
    RegExp(r'\d{2,3}\s*[가-힣]\s*\d{4}'),
    RegExp(r'[가-힣]{2}\s*\d{2,3}\s*[가-힣]\s*\d{4}'),
    RegExp(r'^[가-힣]{2}\s*\d{4}$'),
  ];

  /// 주차 구역 후보 통합 regex.
  ///
  /// 명명 그룹으로 **종류**를 식별한다. alternation 순서상 앞쪽이 우선
  /// 매칭되므로 "B2" 는 basement 그룹으로, "A12" 는 alphanum 그룹으로,
  /// "13" 은 numeric 그룹으로만 들어간다 (중복 매칭 없음).
  static final _zonePattern = RegExp(
    r'(?<basement>\bB\s*\d{1,2}\b)|'
    r'(?<alphanum>\b[A-Z]\s*-?\s*\d{1,3}\b)|'
    r'(?<numeric>\b\d{1,3}\b)',
    caseSensitive: false,
  );

  /// 이미지 파일 경로에서 주차 구역을 인식해 반환한다.
  /// 실패 시 [MlkitOcrResult.empty] (빈 문자열) — 호출자는 수동 입력 플로우로 폴백.
  static Future<MlkitOcrResult> extractZone(String imagePath) async {
    debugPrint('[OCR] 시작: $imagePath');
    final sw = Stopwatch()..start();

    try {
      final result = await _recognize(imagePath).timeout(_timeout);
      debugPrint(
        '[OCR] 완료 (${sw.elapsedMilliseconds}ms): '
        'floor=${result.floor}, zone=${result.zone}, '
        'isBasement=${result.isBasement}, confidence=${result.confidence}',
      );
      return result;
    } on TimeoutException {
      debugPrint('[OCR] 타임아웃 (${sw.elapsedMilliseconds}ms)');
      return MlkitOcrResult.empty;
    } catch (e) {
      debugPrint('[OCR] 실패 (${sw.elapsedMilliseconds}ms): $e');
      return MlkitOcrResult.empty;
    }
  }

  static Future<MlkitOcrResult> _recognize(String imagePath) async {
    // TextRecognizer 는 호출마다 생성·close 해야 재사용 시 네이티브 close()
    // 크래시를 피할 수 있다 (플러그인 이슈 대응 패턴).
    final recognizer = TextRecognizer(script: TextRecognitionScript.korean);
    try {
      final recognized =
          await recognizer.processImage(InputImage.fromFilePath(imagePath));
      if (recognized.blocks.isEmpty) return MlkitOcrResult.empty;

      // 1) 모든 라인을 훑으며 후보 수집. 번호판으로 보이는 라인은 통째로 스킵.
      final candidates = <_Candidate>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          if (_isLicensePlate(line.text)) continue;
          _collectCandidates(line.text, line.boundingBox, candidates);
        }
      }
      debugPrint('[OCR] 후보 수: ${candidates.length}');
      if (candidates.isEmpty) return MlkitOcrResult.empty;

      // 2) 동일 텍스트 중복 제거 — 가장 큰 bbox 만 유지.
      final dedup = <String, _Candidate>{};
      for (final c in candidates) {
        final prev = dedup[c.text];
        if (prev == null || c.area > prev.area) dedup[c.text] = c;
      }

      // 3) 가장 큰 면적 후보 선정.
      final winner = dedup.values.reduce((a, b) => a.area >= b.area ? a : b);
      debugPrint(
        '[OCR] 선정: "${winner.text}" '
        '(area=${winner.area.toStringAsFixed(0)}, '
        'basement=${winner.isBasementMarker})',
      );

      // 4) B 마커면 floor 처리, 아니면 zone 으로 그대로 담는다.
      if (winner.isBasementMarker) {
        final digits = RegExp(r'\d+').firstMatch(winner.text)?.group(0) ?? '';
        return MlkitOcrResult(
          floor: digits,
          zone: '',
          isBasement: true,
          confidence: 'high',
        );
      }
      return MlkitOcrResult(
        floor: '',
        zone: winner.text,
        isBasement: false,
        confidence: 'high',
      );
    } finally {
      await recognizer.close();
    }
  }

  /// 라인 텍스트가 번호판 패턴 중 하나에라도 매칭되면 true.
  static bool _isLicensePlate(String text) {
    for (final p in _licensePlatePatterns) {
      if (p.hasMatch(text)) return true;
    }
    return false;
  }

  /// 라인 내 모든 구역 후보를 추출해 [out] 에 누적한다.
  /// 같은 라인에서 동일 정규화 텍스트는 한 번만 담는다.
  static void _collectCandidates(
    String text,
    Rect bbox,
    List<_Candidate> out,
  ) {
    final seenInLine = <String>{};
    for (final m in _zonePattern.allMatches(text)) {
      final raw = m.group(0);
      if (raw == null || raw.trim().isEmpty) continue;
      final normalized = _normalize(raw);
      if (!seenInLine.add(normalized)) continue;

      final isBasement = m.namedGroup('basement') != null;
      out.add(_Candidate(
        text: normalized,
        bbox: bbox,
        isBasementMarker: isBasement,
      ));
    }
  }

  /// 공백 제거 + 대문자 정규화. "B 2" → "B2", "a-12" → "A-12".
  static String _normalize(String s) =>
      s.replaceAll(RegExp(r'\s+'), '').toUpperCase();
}

/// 라인 단위로 추출된 구역 후보 + 위치 + 타입 플래그.
class _Candidate {
  final String text;
  final Rect bbox;
  final bool isBasementMarker;

  const _Candidate({
    required this.text,
    required this.bbox,
    required this.isBasementMarker,
  });

  double get area => bbox.width * bbox.height;
}
