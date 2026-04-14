import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// OCR 인식 결과 모델.
///
/// [zone]: 인식된 주차 구역 문자열 (예: "B2", "A-12", "지하 2층")
/// [confidence]: 패턴 매칭 점수 (높을수록 우선순위 높음)
class OcrZoneResult {
  final String zone;
  final int confidence;

  const OcrZoneResult({required this.zone, required this.confidence});
}

/// 스마트 OCR 구역 인식 레포지터리.
///
/// ## 처리 파이프라인
/// 1. ML Kit로 이미지 전체 텍스트 추출
/// 2. 한국 자동차 번호판 패턴 → 제거
/// 3. 주차 구역 패턴 → confidence 점수 부여 후 정렬
/// 4. 최상위 후보 반환
class OcrRepository {
  // ── 번호판 정규식 (제거 대상) ──────────────────────────────────────────────
  // 구형: "12가 3456", "123나 4567"
  // 신형: "가나 1234", "서울 12가 3456"
  static final _licensePlatePatterns = [
    RegExp(r'\d{2,3}\s*[가-힣]\s*\d{4}'),          // 12가3456 / 123나4567
    RegExp(r'[가-힣]{2}\s*\d{2}\s*[가-힣]\s*\d{4}'), // 서울 12가 3456
    RegExp(r'[가-힣]\s*[가-힣]\s*\d{4}'),            // 가나 1234 (전기차 신형)
  ];

  // ── 구역 인식 패턴 (우선순위 descending) ──────────────────────────────────
  // confidence 값이 클수록 확실한 주차 구역 표기
  static final _zonePatterns = [
    // (confidence=100) B1, B2, B3, B1F 등 지하층 코드 (가장 일반적)
    _ZonePattern(
      regex: RegExp(r'\b(B\s*\d{1,2}\s*F?)\b', caseSensitive: false),
      confidence: 100,
      normalize: (m) => m.replaceAll(RegExp(r'\s+'), '').toUpperCase(),
    ),
    // (confidence=95) 지하 N층 / 지상 N층 한글 표기
    _ZonePattern(
      regex: RegExp(r'(지하|지상)\s*(\d{1,2})\s*층'),
      confidence: 95,
      normalize: (m) => m.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ),
    // (confidence=90) A-12, B-04, C-3 등 구역-번호 조합
    _ZonePattern(
      regex: RegExp(r'\b([A-Z])\s*[-–]\s*(\d{1,3})\b', caseSensitive: false),
      confidence: 90,
      normalize: (m) => m.replaceAll(RegExp(r'\s+'), '').toUpperCase(),
    ),
    // (confidence=85) A12, C04 등 알파벳+숫자 직결형
    _ZonePattern(
      regex: RegExp(r'\b([A-Z]\d{1,3})\b', caseSensitive: false),
      confidence: 85,
      normalize: (m) => m.toUpperCase(),
    ),
    // (confidence=80) P1, P2 등 주차(P) 코드
    _ZonePattern(
      regex: RegExp(r'\b(P\s*\d{1,2})\b', caseSensitive: false),
      confidence: 80,
      normalize: (m) => m.replaceAll(RegExp(r'\s+'), '').toUpperCase(),
    ),
    // (confidence=75) 한글 구역 번호: 가-12, 나-3
    _ZonePattern(
      regex: RegExp(r'([가-힣])\s*[-–]\s*(\d{1,3})'),
      confidence: 75,
      normalize: (m) => m.replaceAll(RegExp(r'\s+'), ''),
    ),
    // (confidence=70) 숫자만으로 된 층 표기: "3F", "2F"
    _ZonePattern(
      regex: RegExp(r'\b(\d{1,2})\s*F\b', caseSensitive: false),
      confidence: 70,
      normalize: (m) => m.toUpperCase(),
    ),
  ];

  /// 이미지 파일 경로를 받아 주차 구역 문자열을 반환한다.
  ///
  /// ## 리소스 관리
  /// [TextRecognizer]는 호출마다 생성·해제한다.
  /// 인스턴스 변수로 두면 첫 호출의 close() 이후 두 번째 호출에서 크래시가 발생한다.
  ///
  /// ## 반환값
  /// 구역을 인식하지 못하면 null을 반환한다 (크래시 없음).
  Future<OcrZoneResult?> recognizeZone(String imagePath) async {
    // 호출마다 새 인스턴스를 생성하여 재사용 시 close() 크래시를 방지한다.
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.korean);
    final inputImage = InputImage.fromFilePath(imagePath);

    try {
      final recognizedText = await textRecognizer.processImage(inputImage);
      final rawText = recognizedText.text;

      // 흐린 사진 등으로 텍스트가 없으면 null 반환 (크래시 없음)
      if (rawText.isEmpty) return null;

      // 1단계: 번호판 패턴 제거
      final filtered = _removeLicensePlates(rawText);

      // 2단계: 구역 패턴 추출 및 scoring
      final candidates = _extractZoneCandidates(filtered);

      if (candidates.isEmpty) return null;

      // 3단계: confidence 내림차순 → 첫 번째 후보 반환
      candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
      return candidates.first;
    } finally {
      // finally 보장: processImage 실패 시에도 ML Kit 리소스 해제
      await textRecognizer.close();
    }
  }

  /// 번호판 패턴을 공백으로 치환하여 제거.
  String _removeLicensePlates(String text) {
    var result = text;
    for (final pattern in _licensePlatePatterns) {
      result = result.replaceAll(pattern, ' ');
    }
    return result;
  }

  /// 필터링된 텍스트에서 구역 패턴 후보를 모두 추출.
  List<OcrZoneResult> _extractZoneCandidates(String text) {
    final results = <OcrZoneResult>[];

    for (final zonePattern in _zonePatterns) {
      final matches = zonePattern.regex.allMatches(text);
      for (final match in matches) {
        final raw = match.group(0) ?? '';
        if (raw.trim().isEmpty) continue;

        final normalized = zonePattern.normalize(raw);

        // 중복 제거: 동일 문자열이 이미 있으면 스킵
        final isDuplicate = results.any((r) => r.zone == normalized);
        if (!isDuplicate) {
          results.add(OcrZoneResult(
            zone: normalized,
            confidence: zonePattern.confidence,
          ));
        }
      }
    }

    return results;
  }
}

/// 내부 패턴 정의 헬퍼.
class _ZonePattern {
  final RegExp regex;
  final int confidence;
  final String Function(String) normalize;

  const _ZonePattern({
    required this.regex,
    required this.confidence,
    required this.normalize,
  });
}
