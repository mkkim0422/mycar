// 차량 자동 학습 상태머신 — 실행 가능한 행동 명세(executable spec).
//
// 목적: SecurePrefsHelper(Kotlin)의 학습 알고리즘을 1:1로 충실히 포팅하여, 그동안
// "읽고 추론"으로만 검증하던 핵심 시나리오를 **실제로 실행**해 통과를 증명한다.
// (네이티브 Context/EncryptedSharedPreferences 의존을 제거한 순수 로직 모델 — 코드
//  배선이 아니라 알고리즘 설계의 정확성을 실행으로 확인한다.)
//
// 포팅 대상(파일:심볼):
//   - SecurePrefsHelper.onDrivingStarted / onDrivingStopped
//   - SecurePrefsHelper.registerTripAndMaybeLearn (trip-id 중복제거, {c,t} 득표)
//   - SecurePrefsHelper.addConnectedCandidate / removeConnectedCandidate
//   - SecurePrefsHelper.clearLearningProgress / resetCarLearning
//   - SharedPrefsHelper.shouldFireParkingNotification / markParkingNotificationFired (라치+6h만료)
//   - BluetoothDisconnectReceiver.onReceive (CONNECT/DISCONNECT 분기, resolveTargetCarMac)
//   - BluetoothDisconnectReceiver.isLearningCandidate (이어폰/스피커 제외 키워드)

import 'package:flutter_test/flutter_test.dart';

// ── 상수 (Kotlin 과 동일) ────────────────────────────────────────────────────
const int kMinNewTripGapMs = 20 * 60 * 1000; // MIN_NEW_TRIP_GAP_MS
const int kDistinctTripsToLearn = 2; // DISTINCT_TRIPS_TO_LEARN
const int kLatchMaxAgeMs = 6 * 60 * 60 * 1000; // LATCH_MAX_AGE_MS

/// BluetoothDisconnectReceiver.isLearningCandidate 의 이름 키워드 제외 로직 포팅.
/// (BT 클래스 검사는 테스트에서 isCandidate 파라미터로 대체; 키워드는 실제 포팅)
bool isLearningCandidateByName(String name) {
  final n = name.toLowerCase();
  const exclude = [
    'buds', 'airpod', 'earphone', 'earpod', 'headphone', 'headset',
    'earbud', 'pods', 'freebuds', 'wf-', 'wh-', 'beats', 'galaxy buds',
    'sony wh', 'sony wf', '이어폰', '이어버드', '헤드폰', '헤드셋',
    'speaker', '스피커', 'soundbar', '사운드바', 'soundlink', 'soundcore',
    'boom', 'flip', 'charge', 'pulse', 'clip', 'wonderboom', 'megaboom',
    'jbl', 'bose', 'marshall', '마샬', 'sound link',
  ];
  return !exclude.any((k) => n.contains(k));
}

/// 학습 상태머신 모델 — Kotlin 저장 키와 1:1 대응하는 인메모리 상태.
class CarLearningModel {
  // SecurePrefsHelper
  String? learnedCarMac;
  String? manualCarMac;
  final Map<String, Map<String, int>> votes = {}; // mac -> {c, t}
  final Set<String> connected = {};
  Set<String> driven = {};
  bool isDriving = false;
  int tripSeq = 0;
  int lastDriveSignalAt = 0;

  // SharedPrefsHelper (라치)
  bool latch = false;
  int latchedAt = 0;
  bool btAutoEnabled = true;

  // 테스트 관측용: maybeFire 가 알림을 발사했는가
  int fireCount = 0;

  String? _resolveTarget() => manualCarMac ?? learnedCarMac;

  // ── SharedPrefsHelper 라치 ────────────────────────────────────────────────
  bool _shouldFire(int now) {
    if (!latch) return true;
    if (latchedAt > 0 && (now - latchedAt) > kLatchMaxAgeMs) {
      latch = false;
      return true;
    }
    return false;
  }

  void _markFired(int now) {
    latch = true;
    latchedAt = now;
  }

  void clearLatch() => latch = false;

  /// MotionDetectionService.fireParkingNotification 의 발사 가드(자동토글+라치 dedup).
  bool _maybeFire(int now) {
    if (!btAutoEnabled) return false;
    if (!_shouldFire(now)) return false;
    _markFired(now);
    fireCount++;
    return true;
  }

  // ── SecurePrefsHelper.clearLearningProgress ───────────────────────────────
  void clearLearningProgress() {
    votes.clear();
    connected.clear();
    driven = {};
    isDriving = false;
    tripSeq = 0;
    lastDriveSignalAt = 0;
  }

  void resetCarLearning() {
    learnedCarMac = null;
    clearLearningProgress();
    clearLatch();
  }

  void setManualCar(String mac) {
    manualCarMac = mac.toUpperCase();
    clearLearningProgress();
  }

  void clearManualCar() {
    manualCarMac = null;
    clearLearningProgress();
  }

  // ── ACL_CONNECTED ─────────────────────────────────────────────────────────
  void onConnect(String mac, {required bool isCandidate}) {
    final m = mac.toUpperCase();
    final target = _resolveTarget();
    if (target != null) {
      if (m == target) clearLatch(); // 내 차 재연결 → 새 사이클
      return;
    }
    // 학습 모드: 후보만 connected 등록 (운전 중이면 driven 에도 즉시)
    if (isCandidate) {
      connected.add(m);
      if (isDriving) driven.add(m);
    }
  }

  // ── IN_VEHICLE ENTER ──────────────────────────────────────────────────────
  void onDrivingEnter(int now) {
    final wasDriving = isDriving;
    final lastSignal = lastDriveSignalAt;
    isDriving = true;
    lastDriveSignalAt = now;
    if (wasDriving) {
      driven.addAll(connected);
    } else {
      final isNewJourney =
          lastSignal == 0 || (now - lastSignal) > kMinNewTripGapMs;
      if (isNewJourney) tripSeq += 1;
      driven = {};
      driven.addAll(connected);
    }
    // ENTER 에서도 라치 해제(재연결 누락 6h 차단 보강)
    clearLatch();
  }

  // ── IN_VEHICLE EXIT ───────────────────────────────────────────────────────
  void onDrivingExit(int now) {
    isDriving = false;
    lastDriveSignalAt = now;
  }

  // ── SecurePrefsHelper.registerTripAndMaybeLearn ──────────────────────────
  bool _registerTripAndMaybeLearn(String mac) {
    final m = mac.toUpperCase();
    if (!driven.contains(m)) return false;
    driven.remove(m);
    final trip = tripSeq;
    final entry = votes[m] ?? {'c': 0, 't': -1};
    var count = entry['c']!;
    final lastTrip = entry['t']!;
    if (lastTrip != trip) {
      count += 1;
      entry['c'] = count;
      entry['t'] = trip;
      votes[m] = entry;
    }
    if (count >= kDistinctTripsToLearn) {
      learnedCarMac = m;
      votes.clear();
      connected.clear();
      driven = {};
      return true;
    }
    return false;
  }

  // ── ACL_DISCONNECTED ──────────────────────────────────────────────────────
  void onDisconnect(String mac, int now) {
    final m = mac.toUpperCase();
    connected.remove(m); // OFF 여부와 무관하게 정리 먼저
    if (!btAutoEnabled) return;

    final target = _resolveTarget();
    if (target != null) {
      if (m == target) _maybeFire(now); // 내 차만 발사
      return;
    }
    // 학습 모드
    final justLearned = _registerTripAndMaybeLearn(m);
    if (justLearned) _maybeFire(now);
  }

  int voteCount(String mac) => votes[mac.toUpperCase()]?['c'] ?? 0;
}

// ── 시간 헬퍼 ────────────────────────────────────────────────────────────────
int min(int m) => m * 60 * 1000;
int hours(int h) => h * 60 * 60 * 1000;

void main() {
  group('isLearningCandidate 키워드 필터', () {
    test('lightspeaker7 같은 스피커는 후보에서 제외(원래 버그)', () {
      expect(isLearningCandidateByName('lightspeaker7'), isFalse);
      expect(isLearningCandidateByName('Galaxy Buds Pro'), isFalse);
      expect(isLearningCandidateByName('JBL Flip 6'), isFalse);
      expect(isLearningCandidateByName('Sony WH-1000XM5'), isFalse);
      expect(isLearningCandidateByName('내 이어폰'), isFalse);
    });
    test('차량스러운 이름은 후보로 통과', () {
      expect(isLearningCandidateByName('HYUNDAI'), isTrue);
      expect(isLearningCandidateByName('My Car Audio'), isTrue);
      expect(isLearningCandidateByName('BMW 520d'), isTrue);
    });
  });

  group('단일 주행으로는 학습/오학습되지 않음', () {
    test('S1: 스피커 끊김 → 무득표·무발사 (후보 아님)', () {
      final m = CarLearningModel();
      m.onConnect('SP:01', isCandidate: false); // 스피커 → 후보 아님
      m.onDrivingEnter(min(0));
      m.onDisconnect('SP:01', min(10));
      expect(m.voteCount('SP:01'), 0);
      expect(m.fireCount, 0);
      expect(m.learnedCarMac, isNull);
    });

    test('S3: 한 주행 중 플리커(끊김→재연결→끊김) → 1표만', () {
      final m = CarLearningModel();
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(min(0)); // trip 1
      m.onDisconnect('CAR', min(5)); // 플리커 끊김 → 1표
      m.onConnect('CAR', isCandidate: true); // 재연결
      m.onDisconnect('CAR', min(8)); // 주차 끊김 → 같은 trip → 무가산
      expect(m.voteCount('CAR'), 1);
      expect(m.learnedCarMac, isNull);
    });

    test('S4: 플리커 + 가짜 EXIT/ENTER(20분 미만) → 여전히 1표 (Item4 차단)', () {
      final m = CarLearningModel();
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(min(0)); // trip 1
      m.onDisconnect('CAR', min(5)); // 플리커 → trip1 1표
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingExit(min(7)); // 가짜 EXIT
      m.onDrivingEnter(min(10)); // 공백 3분 < 20분 → 같은 trip 유지
      m.onDisconnect('CAR', min(30)); // 주차 → trip1 → 무가산
      expect(m.tripSeq, 1, reason: '20분 미만 EXIT/ENTER 는 새 trip 아님');
      expect(m.voteCount('CAR'), 1);
      expect(m.learnedCarMac, isNull);
    });

    test('S5: 20분 내 짧은 두 주행 → 1trip 으로 합쳐 1표 (안전한 과소계수)', () {
      final m = CarLearningModel();
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(min(0)); // trip 1
      m.onDisconnect('CAR', min(5)); // 1표
      m.onDrivingExit(min(5)); // lastSignal=5분
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(min(10)); // 공백 5분 < 20분 → 같은 trip
      m.onDisconnect('CAR', min(12));
      expect(m.voteCount('CAR'), 1);
      expect(m.learnedCarMac, isNull);
    });

    test('S6: 전원 꺼져 끊김 이벤트 없는 스테일 기기 → 무득표', () {
      final m = CarLearningModel();
      m.onConnect('GHOST', isCandidate: true);
      m.onDrivingEnter(min(0));
      // 끊김 없음 — 새 주행만 반복
      m.onDrivingExit(min(30));
      m.onDrivingEnter(hours(3));
      m.onDrivingExit(hours(3) + min(20));
      expect(m.voteCount('GHOST'), 0);
      expect(m.learnedCarMac, isNull);
    });
  });

  group('정상 학습', () {
    test('S2: 서로 다른 두 주행(시간차) → 2표 → 2회차에 학습+발사', () {
      final m = CarLearningModel();
      // 주행 1
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(min(0)); // trip 1
      m.onDisconnect('CAR', min(10)); // 1표
      m.onDrivingExit(min(10));
      expect(m.voteCount('CAR'), 1);
      expect(m.learnedCarMac, isNull);
      expect(m.fireCount, 0, reason: '학습 전엔 무발사');
      // 주행 2 (몇 시간 뒤)
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(hours(3)); // 공백>20분 → trip 2
      expect(m.tripSeq, 2);
      m.onDisconnect('CAR', hours(3) + min(15)); // 2표 → 학습 + 발사
      expect(m.learnedCarMac, 'CAR');
      expect(m.fireCount, 1);
    });
  });

  group('학습 후 동작', () {
    CarLearningModel learnedModel() {
      final m = CarLearningModel();
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(min(0));
      m.onDisconnect('CAR', min(10));
      m.onDrivingExit(min(10));
      m.onConnect('CAR', isCandidate: true);
      m.onDrivingEnter(hours(3));
      m.onDisconnect('CAR', hours(3) + min(15)); // 학습+1발사
      return m;
    }

    test('S7: 학습 후 다른 기기 끊김은 무시, 내 차만 발사', () {
      final m = learnedModel();
      expect(m.fireCount, 1);
      // 다른 기기 끊김 → 무시
      m.onConnect('OTHER', isCandidate: true);
      m.onDisconnect('OTHER', hours(4));
      expect(m.fireCount, 1);
      // 내 차 재연결(라치 해제) → 주차 끊김 → 발사
      m.onConnect('CAR', isCandidate: true); // 재연결 → clearLatch
      m.onDisconnect('CAR', hours(5));
      expect(m.fireCount, 2);
    });

    test('라치: 한 사이클 1회 — 플리커 중복 끊김은 1발사', () {
      final m = learnedModel(); // fire=1, 라치 set
      m.onDisconnect('CAR', hours(3) + min(16)); // 즉시 재끊김 → 라치로 차단
      expect(m.fireCount, 1);
    });

    test('라치 6h 만료: 재연결 누락돼도 6시간 뒤 발사', () {
      final m = learnedModel(); // 라치 set at 3h+15m
      // 재연결/ENTER 없이 7시간 뒤 끊김
      m.onDisconnect('CAR', hours(3) + min(15) + hours(7));
      expect(m.fireCount, 2);
    });

    test('IN_VEHICLE ENTER 가 라치 해제 → 재연결 누락돼도 다음 주차 발사', () {
      final m = learnedModel(); // 라치 set
      m.onDrivingEnter(hours(4)); // 재연결 브로드캐스트 누락, 운전만 감지 → 라치 해제
      m.onDisconnect('CAR', hours(4) + min(20));
      expect(m.fireCount, 2);
    });
  });

  group('수동 태깅 / 토글 / 리셋', () {
    test('S8: 수동 태깅이 학습보다 우선 — 태깅 기기만 발사', () {
      final m = CarLearningModel();
      m.setManualCar('MANUAL');
      m.onConnect('CAR', isCandidate: true); // target 존재 → 학습 추적 안 함
      m.onDrivingEnter(min(0));
      m.onDisconnect('CAR', min(10)); // 수동차 아님 → 무시
      expect(m.fireCount, 0);
      m.onDisconnect('MANUAL', min(11)); // 수동차 → 발사
      expect(m.fireCount, 1);
    });

    test('S9: clearManualCar 가 묵은 표를 비워 단일주행 오학습 차단', () {
      final m = CarLearningModel();
      // 학습 진행(carA 1표)
      m.onConnect('A', isCandidate: true);
      m.onDrivingEnter(min(0));
      m.onDisconnect('A', min(10));
      expect(m.voteCount('A'), 1);
      // 수동 태깅 B 설정 → 진행상태 클리어
      m.setManualCar('B');
      expect(m.voteCount('A'), 0);
      // 수동 해제 → 또 클리어
      m.clearManualCar();
      // carA 로 한 번만 주행
      m.onConnect('A', isCandidate: true);
      m.onDrivingEnter(hours(5));
      m.onDisconnect('A', hours(5) + min(10));
      expect(m.voteCount('A'), 1, reason: '묵은 표 없이 새로 1표');
      expect(m.learnedCarMac, isNull, reason: '단일 주행으로 학습되면 안 됨');
    });

    test('BT 자동감지 OFF: 무발사 + connected 정리는 수행', () {
      final m = CarLearningModel();
      m.btAutoEnabled = false;
      m.onConnect('CAR', isCandidate: true);
      expect(m.connected.contains('CAR'), isTrue);
      m.onDisconnect('CAR', min(10)); // 정리는 되고 발사는 안 됨
      expect(m.connected.contains('CAR'), isFalse);
      expect(m.fireCount, 0);
    });

    test('resetCarLearning: 학습차·진행상태·라치 모두 초기화', () {
      final m = CarLearningModel();
      m.learnedCarMac = 'CAR';
      m.latch = true;
      m.votes['X'] = {'c': 1, 't': 1};
      m.resetCarLearning();
      expect(m.learnedCarMac, isNull);
      expect(m.latch, isFalse);
      expect(m.votes.isEmpty, isTrue);
    });
  });
}
