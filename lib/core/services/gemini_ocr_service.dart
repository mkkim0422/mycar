import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Gemini Vision API 가 반환한 주차 구역 인식 힌트.
///
/// 바텀시트의 층/구역 입력 필드를 **사전 채움**하는 데만 쓰이며,
/// 사용자는 언제든 수동으로 수정할 수 있다.
class GeminiOcrResult {
  /// 층 숫자 문자열. "B2" 에서 "2" 만, "지상 3층" 에서 "3" 만 담긴다.
  /// 빈 문자열이면 자동 채움 없음.
  final String floor;

  /// 구역 번호 문자열. "13", "A-4", "P5" 등. 빈 문자열이면 자동 채움 없음.
  final String zone;

  /// 지하 주차장 여부. floor 가 "B" 로 시작했으면 true.
  /// 바텀시트의 지상/지하 토글 초기값으로 사용.
  final bool isBasement;

  /// 모델이 보고한 신뢰도. "high" | "medium" | "low".
  /// "low" 인 경우 zone 은 호출자 측에서 빈 문자열로 비우고 반환한다.
  final String confidence;

  const GeminiOcrResult({
    required this.floor,
    required this.zone,
    required this.isBasement,
    required this.confidence,
  });
}

/// Google Gemini 2.0 Flash Vision 을 이용한 주차 구역 OCR 서비스.
///
/// Google AI Studio 무료 티어(분당 15 req, 일 1500 req)로 주차장 촬영 빈도를
/// 여유 있게 커버한다.
///
/// ## 파이프라인
/// 1. JPEG 파일을 Isolate 에서 base64 로 인코딩 (메인 스레드 블로킹 방지)
/// 2. `generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent`
///    에 `inline_data` + 프롬프트를 담아 POST
/// 3. 응답 텍스트에서 JSON 객체 추출 (모델이 markdown 감싸도 대응)
/// 4. floor/zone/confidence 파싱, "B" prefix 로 지상/지하 판별
/// 5. confidence == low 면 zone 을 빈 문자열로 비워 호출자에게 전달
///
/// ## 실패 처리
/// 네트워크 오류, 타임아웃, 4xx/5xx, JSON 파싱 실패 등 어떤 상황에서도 null
/// 을 반환한다 → 호출자는 수동 입력 플로우로 폴백한다. 예외를 throw 하지
/// 않으므로 촬영 흐름을 차단하지 않는다.
class GeminiOcrService {
  GeminiOcrService._();

  /// 요청 전체 (업로드 + 모델 추론 + 응답)에 걸리는 최대 시간.
  /// 5초 — 모바일 네트워크에서도 여유 있게 통과하는 값.
  static const _timeout = Duration(seconds: 5);

  /// 주차장 사진 전용 OCR 프롬프트. 번호판·안내표지 등 잡음을 명시적으로
  /// 배제하고 기둥의 구역 번호 **하나만** JSON 으로 뽑도록 지시한다.
  static const _prompt = '''이 사진은 지하주차장입니다.
기둥 콘크리트 표면에 직접 페인트칠되거나 스티커로 붙어있는 주차 구역 번호 하나만 찾으세요.
무시할 것: 번호판, 천장 안내판, SOS, OUT, 화살표, 벽면 구역 표시, 소화기 라벨
반환 형식 (JSON만):
{"floor": "2", "zone": "13", "confidence": "high"}
confidence가 low면 zone을 빈 문자열로''';

  /// 주어진 이미지 파일에서 주차 구역을 인식해 반환한다.
  ///
  /// API 키 미설정, 네트워크 오류, 타임아웃, 파싱 실패 등 모든 실패는 null.
  static Future<GeminiOcrResult?> extractZone(String imagePath) async {
    if (!AppConfig.isGeminiConfigured) return null;

    try {
      // 1) base64 인코딩은 5~10MB JPEG 에서 수십 ms 메인 스레드 블로킹을
      //    유발할 수 있으므로 Isolate 로 오프로드.
      final base64Image = await compute(_encodeBase64, imagePath);
      if (base64Image == null) return null;

      // 2) Gemini generateContent API 호출.
      //    - 키는 URL query 로 전달 (Google API 표준)
      //    - response_mime_type="application/json" 으로 마크다운 감싸짐 방지
      //    - temperature 0 → 같은 이미지에 대해 동일한 답변 유도
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-2.0-flash:generateContent'
        '?key=${AppConfig.geminiApiKey}',
      );
      final response = await http
          .post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {
                      'inline_data': {
                        'mime_type': 'image/jpeg',
                        'data': base64Image,
                      },
                    },
                    {'text': _prompt},
                  ],
                },
              ],
              'generationConfig': {
                'maxOutputTokens': 100,
                'temperature': 0,
                'responseMimeType': 'application/json',
              },
            }),
          )
          .timeout(_timeout);

      if (response.statusCode != 200) {
        debugPrint(
          '[GeminiOcrService] ${response.statusCode}: ${response.body}',
        );
        return null;
      }

      // 3) 응답 → 텍스트 추출
      //    Gemini 응답 구조: candidates[0].content.parts[0].text
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body is! Map<String, dynamic>) return null;
      final candidates = body['candidates'];
      if (candidates is! List || candidates.isEmpty) return null;
      final first = candidates.first;
      if (first is! Map<String, dynamic>) return null;
      final content = first['content'];
      if (content is! Map<String, dynamic>) return null;
      final parts = content['parts'];
      if (parts is! List || parts.isEmpty) return null;
      final firstPart = parts.first;
      if (firstPart is! Map<String, dynamic>) return null;
      final text = firstPart['text'];
      if (text is! String) return null;

      // 4) 텍스트에서 JSON 블록 추출. responseMimeType=json 이라 보통 순수
      //    JSON 이지만, 모델이 ```json ... ``` 로 감싸거나 설명 문장을 붙이는
      //    케이스도 안전하게 처리되도록 기존 regex 추출 로직을 유지한다.
      final match = RegExp(r'\{[^{}]*\}').firstMatch(text);
      if (match == null) return null;
      final parsed = jsonDecode(match.group(0)!);
      if (parsed is! Map<String, dynamic>) return null;

      final floorRaw = _asTrimmedString(parsed['floor']);
      final zoneRaw = _asTrimmedString(parsed['zone']);
      final confidence = _asTrimmedString(parsed['confidence']).toLowerCase();

      // 5) 지상/지하 판별: floor 가 "B"/"b" 로 시작하면 지하.
      //    이후 숫자만 남겨 floor 필드로 넘긴다. ("B2" → "2", "지하 2" → "2")
      final isBasement = floorRaw.toUpperCase().startsWith('B');
      final floorNumber = _stripFloorPrefix(floorRaw);

      // low confidence 면 zone 은 비워 수동 입력 유도.
      final finalZone = confidence == 'low' ? '' : zoneRaw;

      return GeminiOcrResult(
        floor: floorNumber,
        zone: finalZone,
        isBasement: isBasement,
        confidence: confidence,
      );
    } catch (e) {
      debugPrint('[GeminiOcrService] extractZone 실패: $e');
      return null;
    }
  }

  /// `null`/`int`/`String` 혼재 응답을 안전하게 trimmed String 으로 정규화.
  static String _asTrimmedString(Object? v) {
    if (v == null) return '';
    return v.toString().trim();
  }

  /// "B2"/"b3"/"지하 2" 같은 입력에서 층 **숫자**만 추출한다.
  /// 숫자가 없으면 원문을 그대로 반환 (자유 텍스트 대응).
  static String _stripFloorPrefix(String raw) {
    if (raw.isEmpty) return '';
    // 맨 앞 B/b 제거
    var s = raw.replaceFirst(RegExp(r'^[Bb]'), '').trim();
    // "지하"/"지상" prefix 제거
    s = s.replaceFirst(RegExp(r'^(지하|지상)\s*'), '').trim();
    // 뒤의 "층" 제거
    s = s.replaceFirst(RegExp(r'\s*층$'), '').trim();
    // 순수 숫자가 있으면 그것만, 아니면 정제된 자유 텍스트
    final digits = RegExp(r'\d+').firstMatch(s);
    return digits?.group(0) ?? s;
  }
}

/// 이미지 파일을 읽어 base64 문자열로 반환. 실패 시 null.
/// [compute] 에서 실행되도록 top-level 함수로 선언.
String? _encodeBase64(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    return base64Encode(bytes);
  } catch (_) {
    return null;
  }
}
