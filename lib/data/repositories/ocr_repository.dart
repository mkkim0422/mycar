import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// OCR 인식 결과 모델.
///
/// [zone]: 인식된 주차 구역 문자열 (예: "B2 K4", "A-12", "지하 2층")
/// [confidence]: 패턴 신뢰도 + 글자 크기 가중치 합산 점수 (높을수록 우선순위 높음)
class OcrZoneResult {
  final String zone;
  final int confidence;

  const OcrZoneResult({required this.zone, required this.confidence});
}

/// 스마트 OCR "구역 중심" 인식 레포지터리.
///
/// ## 처리 파이프라인 (Zone-Centric + Privacy)
/// 1. ML Kit(Korean script)로 블록/라인/바운딩박스 추출
/// 2. 라인 단위로 번호판 패턴이면 통째로 폐기 (프라이버시 필터)
/// 3. 구역 패턴 매칭 → 패턴 신뢰도 + 상대 글자 크기로 스코어링
/// 4. 한 라인 내 복수 토큰(예: "B2 K4")은 묶어서 하나의 구역 텍스트로 구성
/// 5. 최상위 스코어 후보 반환
///
/// ## 왜 블록 면적(면적 = 폭×높이)이 중요한가
/// 기둥/표지판의 주차 구역 라벨은 환경상 가장 큰 글자로 적혀 있는 경우가 많다.
/// 반면 화살표/안내 문구("G →", "출구") 등 주변 노이즈는 작은 글자로 존재한다.
/// 따라서 "가장 큰 구역 패턴"을 고르면 촬영 의도에 가장 가까운 결과가 나온다.
class OcrRepository {
  // ── 번호판 정규식 (DETECT → DISCARD: 개인정보 보호) ────────────────────────
  // 구형: "12가 3456", "123나 4567"
  // 신형: "12가3456", "서울 12가 3456", "가나 1234" (전기차 일부)
  static final _licensePlatePatterns = [
    RegExp(r'\d{2,3}\s*[가-힣]\s*\d{4}'),
    RegExp(r'[가-힣]{2}\s*\d{2,3}\s*[가-힣]\s*\d{4}'),
    RegExp(r'^[가-힣]{2}\s*\d{4}$'),
  ];

  // ── 주차 구역 패턴 (신뢰도 내림차순) ───────────────────────────────────────
  static final _zonePatterns = <_ZonePattern>[
    // (100) B1, B2, B3, B1F 등 지하층 코드
    _ZonePattern(
      regex: RegExp(r'\bB\s*\d{1,2}\s*F?\b', caseSensitive: false),
      confidence: 100,
      normalize: _stripAndUpper,
    ),
    // (95) 지하 N층 / 지상 N층 (한글)
    _ZonePattern(
      regex: RegExp(r'(지하|지상)\s*\d{1,2}\s*층'),
      confidence: 95,
      normalize: (s) => s.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ),
    // (90) A-12, B-04, C-3 등 구역-번호 조합
    _ZonePattern(
      regex: RegExp(r'\b[A-Z]\s*[-–]\s*\d{1,3}\b', caseSensitive: false),
      confidence: 90,
      normalize: _stripAndUpper,
    ),
    // (85) A12, C04, K4 등 알파벳+숫자 직결형
    _ZonePattern(
      regex: RegExp(r'\b[A-Z]\d{1,3}\b', caseSensitive: false),
      confidence: 85,
      normalize: _stripAndUpper,
    ),
    // (80) P1, P2 등 주차(P) 코드
    _ZonePattern(
      regex: RegExp(r'\bP\s*\d{1,2}\b', caseSensitive: false),
      confidence: 80,
      normalize: _stripAndUpper,
    ),
    // (75) 한글 구역: 가-12, 나-3
    _ZonePattern(
      regex: RegExp(r'[가-힣]\s*[-–]\s*\d{1,3}'),
      confidence: 75,
      normalize: (s) => s.replaceAll(RegExp(r'\s+'), ''),
    ),
    // (70) 숫자만으로 된 층 표기: 3F, 2F
    _ZonePattern(
      regex: RegExp(r'\b\d{1,2}\s*F\b', caseSensitive: false),
      confidence: 70,
      normalize: _stripAndUpper,
    ),
    // (65) "12구역", "3구역" 등 한글 구역 번호 표기
    _ZonePattern(
      regex: RegExp(r'\d{1,3}\s*구역'),
      confidence: 65,
      normalize: (s) => s.replaceAll(RegExp(r'\s+'), ''),
    ),
  ];

  /// 이미지 파일 경로를 받아 가장 유력한 주차 구역을 반환.
  ///
  /// ## 파이프라인
  /// 1. 모든 라인의 구역-패턴 매치를 바운딩박스와 함께 수집 (`_Hit`).
  /// 2. 같은 텍스트(예: "B2")가 여러 번 잡히면 **가장 큰 바운딩박스 하나만 유지**.
  ///    → 멀리 있는 기둥의 "B2"가 앞 기둥의 "B2" 를 중복 출력하는 문제 방지.
  /// 3. (패턴 신뢰도 + 상대 면적) 점수로 **주 구역(primary)** 선정.
  /// 4. primary 와 **수직으로 인접**하고 수평 범위가 겹치는 다른 히트들을 병합.
  ///    → 동일 기둥에 수직 스택된 "B2"/"K4"를 하나의 라벨로 결합.
  /// 5. 읽기 순서(위→아래, 왼→오)로 정렬 후 공백으로 연결 → "B2 K4".
  ///
  /// 구역을 인식하지 못하거나 입력이 비었으면 null을 반환한다 (크래시 없음).
  /// [TextRecognizer]는 호출마다 생성·해제하여 재사용 시 close() 크래시를 방지한다.
  Future<OcrZoneResult?> recognizeZone(String imagePath) async {
    final textRecognizer =
        TextRecognizer(script: TextRecognitionScript.korean);
    final inputImage = InputImage.fromFilePath(imagePath);

    try {
      final recognized = await textRecognizer.processImage(inputImage);
      if (recognized.blocks.isEmpty) return null;

      // 1) 모든 구역-패턴 히트 수집 (라인 단위, 번호판 라인은 폐기)
      final allHits = <_Hit>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          if (_containsLicensePlate(line.text)) continue;
          _collectHits(line.text, line.boundingBox, allHits);
        }
      }
      if (allHits.isEmpty) return null;

      // 2) 동일 텍스트 중복 제거 — 가장 큰 바운딩박스만 유지
      final dedupByText = <String, _Hit>{};
      for (final h in allHits) {
        final prev = dedupByText[h.text];
        if (prev == null || h.area > prev.area) dedupByText[h.text] = h;
      }
      final uniqueHits = dedupByText.values.toList();

      // 3) 점수 계산 (패턴 신뢰도 + 상대 면적 가산 0~50) → 주 구역 선정
      double maxArea = 0;
      for (final h in uniqueHits) {
        if (h.area > maxArea) maxArea = h.area;
      }
      if (maxArea <= 0) maxArea = 1;
      int scoreOf(_Hit h) =>
          h.confidence + ((h.area / maxArea) * 50).round();

      uniqueHits.sort((a, b) => scoreOf(b).compareTo(scoreOf(a)));
      final primary = uniqueHits.first;

      // 4) primary 와 공간적으로 인접한 히트를 병합 (같은 기둥에 적힌 정보)
      final merged = <_Hit>[primary];
      for (final h in uniqueHits) {
        if (identical(h, primary)) continue;
        if (_isSpatiallyAdjacent(primary.bbox, h.bbox)) {
          merged.add(h);
        }
      }

      // 5) 읽기 순서로 정렬 후 공백으로 연결 (중복 텍스트 제거)
      merged.sort((a, b) {
        final dy = a.bbox.top.compareTo(b.bbox.top);
        return dy != 0 ? dy : a.bbox.left.compareTo(b.bbox.left);
      });

      final seen = <String>{};
      final parts = <String>[];
      for (final h in merged) {
        if (seen.add(h.text)) parts.add(h.text);
      }

      return OcrZoneResult(
        zone: parts.join(' ').trim(),
        confidence: scoreOf(primary),
      );
    } finally {
      await textRecognizer.close();
    }
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  bool _containsLicensePlate(String text) {
    for (final p in _licensePlatePatterns) {
      if (p.hasMatch(text)) return true;
    }
    return false;
  }

  /// 한 라인 텍스트에서 모든 구역-패턴 매치를 바운딩박스와 함께 누적.
  /// 라인 내부에서 동일 정규화 텍스트는 한 번만 추가한다 (라인 간 중복은 이후 dedup).
  void _collectHits(String lineText, Rect bbox, List<_Hit> out) {
    final seenInLine = <String>{};
    for (final pattern in _zonePatterns) {
      for (final m in pattern.regex.allMatches(lineText)) {
        final raw = m.group(0);
        if (raw == null || raw.trim().isEmpty) continue;
        final normalized = pattern.normalize(raw);
        if (normalized.isEmpty) continue;
        if (!seenInLine.add(normalized)) continue;
        out.add(_Hit(
          text: normalized,
          bbox: bbox,
          confidence: pattern.confidence,
        ));
      }
    }
  }

  /// 두 바운딩박스가 같은 기둥/표지판에 속할 정도로 가까운가?
  /// - 수직 간격이 두 박스 중 더 큰 높이의 1.5배 이내
  /// - 수평 범위가 조금이라도 겹침
  static bool _isSpatiallyAdjacent(Rect primary, Rect other) {
    final slack =
        (primary.height > other.height ? primary.height : other.height) * 1.5;

    double vDist;
    if (other.top > primary.bottom) {
      vDist = other.top - primary.bottom; // other is below
    } else if (primary.top > other.bottom) {
      vDist = primary.top - other.bottom; // other is above
    } else {
      vDist = 0; // vertical overlap
    }
    if (vDist > slack) return false;

    // 수평 겹침 — 완전히 다른 열에 있는 텍스트는 제외
    return other.left < primary.right && other.right > primary.left;
  }

  static String _stripAndUpper(String s) =>
      s.replaceAll(RegExp(r'\s+'), '').toUpperCase();
}

// ── internal types ──────────────────────────────────────────────────────────

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

/// 하나의 라인에서 추출된 단일 구역 후보와 그 위치.
class _Hit {
  final String text;
  final Rect bbox;
  final int confidence;

  const _Hit({
    required this.text,
    required this.bbox,
    required this.confidence,
  });

  double get area => bbox.width * bbox.height;
}
