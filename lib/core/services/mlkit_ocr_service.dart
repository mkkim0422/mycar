/// OCR 결과 데이터 컨테이너.
///
/// v4 (실시간 image stream + 자동 캡처) 부터 OCR 로직 자체는
/// [OcrCameraScreen] 안에서 직접 처리한다. 이 파일은 결과 객체만 남겨
/// `_ResultBottomSheet` 등 기존 시트 인터페이스와의 호환을 유지하는
/// 슬림 데이터 클래스 컨테이너 역할만 한다.
library;

/// On-device ML Kit Text Recognition 으로 자동 캡처된 주차 구역 결과.
///
/// 결과 시맨틱:
///   - [zone]       : 가이드 영역과 교차한 텍스트 중 패턴 필터를 통과한
///                   첫 후보. 패턴 = `[A-Za-z0-9-]{1,5}` + 숫자 1자 이상 포함.
///   - [confidence] : "high" = 자동 캡처 발견, "low" = 인식 실패/매치 없음.
///
/// 호환 필드(기존 시트 인터페이스 유지용):
///   - [floor]      : 항상 빈 문자열. 자동 추출하지 않으며 사용자가 직접 입력.
///   - [isBasement] : 항상 false. 토글은 사용자 수동.
class MlkitOcrResult {
  /// 층 숫자 — 자동 추출하지 않는다. 시트의 floor 필드는 항상 사용자 입력.
  final String floor;

  /// 자동 캡처된 주차 구역 텍스트. 빈 문자열이면 채움 없음.
  final String zone;

  /// 지하 주차장 여부 — 자동 추정하지 않는다. 항상 false.
  final bool isBasement;

  /// "high" = 패턴 필터 통과한 자동 캡처, "low" = 매칭 없음/실패.
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
