package com.snappark.core.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/**
 * ══════════════════════════════════════════════════════════════════════════
 *  SecurePrefsHelper — At-Rest 암호화 SharedPreferences 래퍼
 * ══════════════════════════════════════════════════════════════════════════
 *
 * ## 설계 목표
 * - **민감 데이터만** 별도 암호화 저장소에 보관한다 (BT MAC 주소, 기기 이름).
 *   일반 주차 데이터·위젯 설정은 기존 평문 [SharedPrefsHelper] 를 유지한다.
 *
 * - **네이티브가 저장소를 소유**한다. BluetoothDisconnectReceiver 는 앱 프로세스가
 *   완전히 종료된 상태에서도 실행되므로 Dart VM 에 의존할 수 없다. Flutter
 *   플러그인(flutter_secure_storage) 의 저장 포맷에 결합하지 않고 네이티브에서
 *   직접 EncryptedSharedPreferences 를 다룬다.
 *
 * - **마스터 키는 AndroidKeyStore** 에 저장되어 앱 프로세스 외부(루트 유저 포함)로
 *   추출 불가능하다. 디바이스가 초기화되면 키도 함께 소실되어 저장 값이 복호화
 *   불능 상태가 되는데, 이는 의도된 안전 동작이다 (Fail-Safe Crypto Erase).
 *
 * ## 키 이름 난독화
 * APK 정적 분석 시 `manual_car_id` 등 의미 있는 문자열이 그대로 노출되는 것을
 * 막기 위해, 저장 키를 SHA-256 해시 앞 16자(hex) 로 치환한다.
 * 내부 EncryptedSharedPreferences 층이 키를 또 AES-SIV 로 감싸므로,
 * 디스크 상 키는 이중으로 보호된다.
 *
 * ## 저장되는 평문 예시 (암호화 전)
 *   KEY_MANUAL_CAR_MAC  = "AA:BB:CC:DD:EE:FF"
 *   KEY_MANUAL_CAR_NAME = "내 차량 시스템"
 */
object SecurePrefsHelper {

    /** 파일명 (일반 SharedPrefsHelper 와 분리되어야 암호화 스키마 공존 가능) */
    private const val SECURE_FILE = "SnapParkSecurePrefs"

    /**
     * 키 상수 원본 — 이 값들은 **실제 저장 키가 아니다**.
     * [obf] 로 해시 변환된 값이 디스크에 저장된다.
     */
    private const val RAW_KEY_CAR_MAC = "manual_car_mac_v1"
    private const val RAW_KEY_CAR_NAME = "manual_car_name_v1"

    // ── 차량 자동 학습 (Auto-Learning) 키 ────────────────────────────────────
    //   학습으로 확정된 차량 MAC + 표시 이름. 수동 태깅과 별개 슬롯.
    private const val RAW_KEY_LEARNED_CAR_MAC = "learned_car_mac_v1"
    private const val RAW_KEY_LEARNED_CAR_NAME = "learned_car_name_v1"
    //   후보 MAC → 운전 trip 득표수 (JSON object: {"AA:BB:..": 1})
    private const val RAW_KEY_CANDIDATE_VOTES = "car_candidate_votes_v1"
    //   현재 연결돼 있는 "차량 후보" MAC 집합 (JSON array)
    private const val RAW_KEY_CONNECTED = "car_connected_set_v1"
    //   이번 운전 사이클 동안 연결돼 있던(=운전과 함께한) 후보 MAC 집합 (JSON array)
    private const val RAW_KEY_DRIVEN_CYCLE = "car_driven_cycle_v1"
    //   현재 IN_VEHICLE(운전 중) 여부 플래그
    private const val RAW_KEY_IS_DRIVING = "is_driving_v1"
    //   운전 사이클 일련번호(trip id). 충분히 긴 비운전 공백 뒤의 ENTER 에만 +1.
    private const val RAW_KEY_TRIP_SEQ = "car_trip_seq_v1"
    //   마지막 운전 신호(ENTER/EXIT) 시각(epoch ms). "비운전 공백 길이" 산출용.
    private const val RAW_KEY_LAST_DRIVE_SIGNAL_AT = "car_last_drive_signal_at_v1"

    /**
     * 새 trip(주행)으로 인정하기 위한 **최소 비운전 공백**.
     *
     * AR(IN_VEHICLE)은 노이즈가 있어, 긴 정체·터널·주차장 GPS 소실 시 한 주행
     * 도중에도 EXIT→ENTER 가 튄다. 그 가짜 경계로 trip id 가 올라가면, 같은 주행의
     * BT 플리커 끊김과 주차 끊김이 서로 다른 trip 으로 집계돼 1회 주행만으로 학습되는
     * 구멍이 생긴다(리뷰 Item 4). 직전 운전 신호로부터 이 시간 이상 비운전이었을
     * 때만 새 trip 으로 친다 → 그보다 짧은 EXIT/ENTER 튐은 같은 trip 으로 흡수된다.
     *
     * 정밀도(오학습 0) 우선: 가까운 두 번의 짧은 주행은 한 trip 으로 합쳐져 학습이
     * 느려질 수 있으나(표 부족 → 추가 주행 필요), 이는 안전한 방향의 트레이드오프다.
     */
    private const val MIN_NEW_TRIP_GAP_MS = 20L * 60 * 1000 // 20분

    /**
     * 후보가 "내 차"로 학습되기까지 필요한 서로 다른 운전 trip 횟수.
     *
     * 1 로 두면 이어폰류(클래스 필터 통과 실패분 제외)·1회성 동승 기기까지 빠르게
     * 학습될 위험이 있다. 2 면 "운전하며 연결 → 주차하며 끊김"이 2회 반복돼야
     * 확정되므로, 우연히 한 번 차에서 켠 BT 스피커 등이 차로 오학습되지 않는다.
     * 대가: 학습 완료 전(보통 첫 1~2회 주행)에는 자동 알림이 발사되지 않는다.
     */
    const val DISTINCT_TRIPS_TO_LEARN = 2

    /** 지연 초기화 — 첫 접근 시 한 번만 MasterKey / EncryptedSharedPreferences 생성 */
    @Volatile
    private var cached: SharedPreferences? = null

    private fun prefs(context: Context): SharedPreferences {
        cached?.let { return it }
        return synchronized(this) {
            cached ?: buildEncryptedPrefs(context.applicationContext).also { cached = it }
        }
    }

    private fun buildEncryptedPrefs(appContext: Context): SharedPreferences {
        return runCatching { createEncryptedPrefs(appContext) }.getOrElse { e ->
            // 키스토어/마스터키 손상(백업 복원·키스토어 리셋 등) 시 create 가 영구적으로
            // 던진다. 그대로 두면 학습·수동태깅이 조용히 영구 무력화되므로, 손상된 암호화
            // 파일을 삭제하고 1회 재생성한다(저장돼 있던 MAC 은 소실되나 어차피 복호화
            // 불능 → 안전한 Crypto-Erase).
            //
            // 단, **손상 계열 예외(GeneralSecurityException/IOException — AEADBadTag·
            // InvalidProtocolBuffer 포함)일 때만** 삭제한다. 일시적 오류(메모리·일시 I/O)
            // 로 멀쩡한 MAC 을 지우지 않도록, 그 외 예외는 재던져 호출부 runCatching 이
            // no-op 처리하게 한다(데이터 보존).
            if (e is java.security.GeneralSecurityException || e is java.io.IOException) {
                runCatching { appContext.deleteSharedPreferences(SECURE_FILE) }
                createEncryptedPrefs(appContext)
            } else {
                throw e
            }
        }
    }

    private fun createEncryptedPrefs(appContext: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()

        return EncryptedSharedPreferences.create(
            appContext,
            SECURE_FILE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /**
     * 키 이름 난독화 — SHA-256 앞 16자.
     *
     * 예) "manual_car_mac_v1" → "7b3d0e4c9a18f352"
     * 목적: APK 정적 분석 도구(jadx, apktool)로 덤프된 상수 테이블에서
     *      "manual_car" 같은 의미 있는 문자열이 그대로 보이지 않게 한다.
     */
    private fun obf(rawKey: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(rawKey.toByteArray())
        return digest.take(8).joinToString("") { "%02x".format(it) }
    }

    // ── 공개 API ────────────────────────────────────────────────────────────

    /**
     * 수동 태깅된 차량 BT MAC 주소를 반환한다.
     * 비교 시 대소문자를 통일하기 위해 항상 upper-case 로 정규화.
     */
    fun getManualCarId(context: Context): String? {
        return runCatching {
            prefs(context).getString(obf(RAW_KEY_CAR_MAC), null)?.uppercase()
        }.getOrNull()
    }

    /** 수동 태깅된 차량 기기의 표시용 이름을 반환한다. 없으면 null. */
    fun getManualCarName(context: Context): String? {
        return runCatching {
            prefs(context).getString(obf(RAW_KEY_CAR_NAME), null)
        }.getOrNull()
    }

    /**
     * 차량 MAC + 기기 이름을 암호화 저장한다.
     * MAC 은 upper-case 정규화.
     */
    fun setManualCar(context: Context, mac: String, name: String) {
        runCatching {
            prefs(context).edit()
                .putString(obf(RAW_KEY_CAR_MAC), mac.uppercase())
                .putString(obf(RAW_KEY_CAR_NAME), name)
                .apply()
        }
        // 수동 태깅이 우선권을 가지므로, 진행 중이던 학습 표/집합은 묵은 상태가 된다.
        // 나중에 수동 태깅을 해제했을 때 묵은 표 1개 + 새 주행 1회로 오학습되는 것을
        // 막기 위해 진행 상태를 지운다(확정된 학습차는 보존).
        clearLearningProgress(context)
    }

    /** 수동 태깅 해제. 암호화된 저장소의 키도 모두 제거. */
    fun clearManualCar(context: Context) {
        runCatching {
            prefs(context).edit()
                .remove(obf(RAW_KEY_CAR_MAC))
                .remove(obf(RAW_KEY_CAR_NAME))
                .apply()
        }
        // 수동 태깅을 해제하면 자동 학습으로 복귀한다. 묵은 진행 표가 남아 있으면
        // 새 주행 1회만으로 오학습될 수 있으므로 진행 상태를 깨끗이 비우고 다시 시작한다
        // (이미 확정된 학습차가 있으면 그쪽으로 자연 폴백).
        clearLearningProgress(context)
    }

    // ══════════════════════════════════════════════════════════════════════
    //  차량 자동 학습 (Auto-Learning)
    // ══════════════════════════════════════════════════════════════════════
    //
    //  목표: 사용자가 아무것도 태깅하지 않아도 "내 차 BT"를 스스로 알아낸다.
    //
    //  신호 결합:
    //    1) 연결(ACL_CONNECTED) 시점에 "차량 후보"(오디오 기기·이어폰/스피커 아님)
    //       만 추려 connected set 에 넣는다. (이름이 있는 연결 시점에 판정 → 끊김
    //       시점의 null name 문제 회피)
    //    2) 운전 감지(IN_VEHICLE ENTER)가 오면, 그때 connected set 에 있던 후보를
    //       "이번 운전과 함께한 기기(driven cycle)"로 표시한다.
    //    3) 끊김(ACL_DISCONNECTED) 시 그 기기가 driven cycle 에 있으면 표를 적립.
    //       단 **서로 다른 trip(주행) 당 최대 1표**(trip id 로 중복 제거)로,
    //       DISTINCT_TRIPS_TO_LEARN 표(= 서로 다른 주행 횟수)를 모으면 "내 차"로 확정.
    //
    //  → 집 스피커는 운전과 무관해 표가 안 쌓이고, 이어폰은 1단계에서 후보 탈락.
    //  → 한 번의 주행 중 BT 가 깜빡(끊김→재연결)여도 같은 trip id 라 1표만 인정되어,
    //     "남의 차에 한 번 탑승" 같은 단일 주행으로는 오학습되지 않는다.
    //  → 적립을 "끊김 시점"에만 하므로, 전원이 꺼져 영영 끊기지 않는 스테일 항목은
    //     표를 얻지 못한다(오학습 방지).

    // ── 학습된 차량 MAC ──────────────────────────────────────────────────────

    /** 학습으로 확정된 차량 BT MAC (upper-case). 아직 학습 전이면 null. */
    fun getLearnedCarId(context: Context): String? = runCatching {
        prefs(context).getString(obf(RAW_KEY_LEARNED_CAR_MAC), null)?.uppercase()
    }.getOrNull()

    /** 학습된 차량의 표시 이름. */
    fun getLearnedCarName(context: Context): String? = runCatching {
        prefs(context).getString(obf(RAW_KEY_LEARNED_CAR_NAME), null)
    }.getOrNull()

    private fun setLearnedCar(context: Context, mac: String, name: String) {
        runCatching {
            // commit(): 학습 확정 직후 호출 측이 곧바로 알림을 발사하므로, 프로세스가
            // 직후 종료돼도 "학습됨"이 반드시 디스크에 남아야 한다(미반영 시 다음 사이클에
            // 다시 학습 모드로 떨어져 방금 알림이 일회성처럼 보이는 desync 방지).
            prefs(context).edit()
                .putString(obf(RAW_KEY_LEARNED_CAR_MAC), mac.uppercase())
                .putString(obf(RAW_KEY_LEARNED_CAR_NAME), name)
                .commit()
        }
    }

    /**
     * 진행 중 학습 상태(후보 득표·연결/운전 집합·trip 카운터)만 비운다.
     * **확정된 학습차(MAC/이름)는 보존**한다. 수동 태깅 설정/해제 시 묵은 표 누적을 막는 용도.
     */
    private fun clearLearningProgress(context: Context) {
        synchronized(learnLock) {
            runCatching {
                prefs(context).edit()
                    .remove(obf(RAW_KEY_CANDIDATE_VOTES))
                    .remove(obf(RAW_KEY_CONNECTED))
                    .remove(obf(RAW_KEY_DRIVEN_CYCLE))
                    .remove(obf(RAW_KEY_IS_DRIVING))
                    .remove(obf(RAW_KEY_TRIP_SEQ))
                    .remove(obf(RAW_KEY_LAST_DRIVE_SIGNAL_AT))
                    .apply()
            }
        }
    }

    /**
     * 학습 결과 전체 초기화 — 학습된 차 + 후보 득표 + 진행 중 상태를 모두 비운다.
     * 설정의 "차량 다시 학습하기"에서 호출.
     */
    fun resetCarLearning(context: Context) {
        synchronized(learnLock) {
            runCatching {
                prefs(context).edit()
                    .remove(obf(RAW_KEY_LEARNED_CAR_MAC))
                    .remove(obf(RAW_KEY_LEARNED_CAR_NAME))
                    .remove(obf(RAW_KEY_CANDIDATE_VOTES))
                    .remove(obf(RAW_KEY_CONNECTED))
                    .remove(obf(RAW_KEY_DRIVEN_CYCLE))
                    .remove(obf(RAW_KEY_IS_DRIVING))
                    .remove(obf(RAW_KEY_TRIP_SEQ))
                    .remove(obf(RAW_KEY_LAST_DRIVE_SIGNAL_AT))
                    .apply()
            }
        }
    }

    // ── 연결 후보 집합 ────────────────────────────────────────────────────────

    // 모든 학습 상태 read-modify-write 는 이 락으로 직렬화한다. 매니페스트 리시버는
    // 동일 프로세스 메인 스레드에서 순차 디스패치되지만, 방어적으로 lost-update 를 막는다.
    private val learnLock = Any()

    /** 연결된 차량 후보 MAC 을 집합에 추가. 운전 중이면 즉시 driven cycle 에도 반영. */
    fun addConnectedCandidate(context: Context, mac: String) {
        synchronized(learnLock) {
            runCatching {
                val m = mac.uppercase()
                val set = readSet(context, RAW_KEY_CONNECTED)
                set.add(m)
                writeSet(context, RAW_KEY_CONNECTED, set)
                // 운전 도중에 뒤늦게 연결된 경우에도 이번 trip 에 포함시킨다.
                if (isDriving(context)) {
                    val driven = readSet(context, RAW_KEY_DRIVEN_CYCLE)
                    driven.add(m)
                    writeSet(context, RAW_KEY_DRIVEN_CYCLE, driven)
                }
            }
        }
    }

    /** 연결 후보 집합에서 제거 (끊김 시). */
    fun removeConnectedCandidate(context: Context, mac: String) {
        synchronized(learnLock) {
            runCatching {
                val set = readSet(context, RAW_KEY_CONNECTED)
                if (set.remove(mac.uppercase())) writeSet(context, RAW_KEY_CONNECTED, set)
            }
        }
    }

    // ── 운전 상태 ─────────────────────────────────────────────────────────────

    fun isDriving(context: Context): Boolean = runCatching {
        prefs(context).getBoolean(obf(RAW_KEY_IS_DRIVING), false)
    }.getOrDefault(false)

    /** 현재 운전 사이클 일련번호(trip id). */
    private fun getCurrentTrip(context: Context): Int = runCatching {
        prefs(context).getInt(obf(RAW_KEY_TRIP_SEQ), 0)
    }.getOrDefault(0)

    /**
     * 운전 시작(IN_VEHICLE ENTER). 새 운전 사이클이면 trip id 를 +1 하고 driven cycle 을
     * 새로 시작하며, 현재 연결돼 있는 모든 후보를 "이번 운전과 함께함"으로 표시한다.
     *
     * trip id 증가는 **새 사이클(직전이 비운전)일 때만** — 신호등 정차로 EXIT/ENTER 가
     * 반복돼도 같은 주행은 같은 trip id 를 유지해 1표만 인정되게 한다.
     */
    fun onDrivingStarted(context: Context) {
        synchronized(learnLock) {
            runCatching {
                val now = System.currentTimeMillis()
                val wasDriving = isDriving(context)
                val lastSignal = prefs(context).getLong(obf(RAW_KEY_LAST_DRIVE_SIGNAL_AT), 0L)
                val editor = prefs(context).edit()
                    .putBoolean(obf(RAW_KEY_IS_DRIVING), true)
                    .putLong(obf(RAW_KEY_LAST_DRIVE_SIGNAL_AT), now)
                val driven = if (wasDriving) {
                    readSet(context, RAW_KEY_DRIVEN_CYCLE)
                } else {
                    // 직전 운전 신호로부터 충분히 긴 비운전 공백 뒤일 때만 새 trip 으로 인정.
                    // (짧은 정체로 인한 가짜 EXIT/ENTER 는 같은 trip 으로 흡수 → Item 4 차단)
                    val isNewJourney = lastSignal == 0L || (now - lastSignal) > MIN_NEW_TRIP_GAP_MS
                    if (isNewJourney) editor.putInt(obf(RAW_KEY_TRIP_SEQ), getCurrentTrip(context) + 1)
                    mutableSetOf()
                }
                driven.addAll(readSet(context, RAW_KEY_CONNECTED))
                // driven 집합도 같은 editor 에 담아 단일 apply() 로 원자 커밋한다.
                // (is_driving=true 만 먼저 디스크에 남고 driven 은 누락되는 부분 저장/torn
                //  상태를 제거 — 락 안이지만 프로세스 사망 사이의 부분 영속도 함께 차단)
                editor.putString(
                    obf(RAW_KEY_DRIVEN_CYCLE),
                    JSONArray().apply { driven.forEach { put(it) } }.toString(),
                )
                editor.apply()
            }
        }
    }

    /** 운전 종료(IN_VEHICLE EXIT). driven cycle 은 끊김에서 소비할 때까지 보존한다. */
    fun onDrivingStopped(context: Context) {
        synchronized(learnLock) {
            runCatching {
                prefs(context).edit()
                    .putBoolean(obf(RAW_KEY_IS_DRIVING), false)
                    // 비운전 공백 측정 기준점 갱신 — 다음 ENTER 가 새 trip 인지 판정에 사용.
                    .putLong(obf(RAW_KEY_LAST_DRIVE_SIGNAL_AT), System.currentTimeMillis())
                    .apply()
            }
        }
    }

    // ── 학습 판정 ─────────────────────────────────────────────────────────────

    /**
     * 끊긴 기기가 이번(또는 직전) 운전과 함께했다면 **서로 다른 trip 당 1표**를
     * 적립하고, 누적 표가 [DISTINCT_TRIPS_TO_LEARN](= 서로 다른 주행 횟수) 이상이면
     * 그 기기를 "내 차"로 확정한다.
     *
     * trip id 중복 제거가 핵심: 한 주행 중 BT 가 끊김→재연결→끊김을 반복해도 같은
     * trip id 면 1표만 인정되므로, 단일 주행으로는 절대 학습되지 않는다.
     *
     * 득표 저장 포맷: votes[MAC] = {"c": 누적표, "t": 마지막으로 적립한 trip id}.
     *
     * @return 방금 이 호출로 차량이 **새로 확정**되었으면 true (= 지금 끊김은
     *   "주차 후 하차" 이벤트이기도 하므로 호출 측에서 알림을 발사해도 된다).
     */
    fun registerTripAndMaybeLearn(context: Context, mac: String, name: String?): Boolean {
        synchronized(learnLock) {
            return runCatching {
                val m = mac.uppercase()
                val driven = readSet(context, RAW_KEY_DRIVEN_CYCLE)
                if (!driven.contains(m)) return false // 운전과 무관한 끊김 → 무시

                // 이번 사이클에서 이 기기를 소비(같은 사이클 중복 끊김의 즉각 재적립 방지).
                driven.remove(m)
                writeSet(context, RAW_KEY_DRIVEN_CYCLE, driven)

                val trip = getCurrentTrip(context)
                val votes = readVotes(context)
                // 신포맷 {c,t} 우선. 구포맷(MAC->int)에서 업그레이드된 경우 optInt 로
                // 기존 카운트를 살려 이관(데이터 손실 방지). 둘 다 없으면 신규 {0,-1}.
                val entry = votes.optJSONObject(m)
                    ?: JSONObject().put("c", votes.optInt(m, 0)).put("t", -1)
                var count = entry.optInt("c", 0)
                val lastTrip = entry.optInt("t", -1)

                // 서로 다른 trip 일 때만 +1 (같은 주행의 깜빡임은 중복 제거).
                if (lastTrip != trip) {
                    count += 1
                    entry.put("c", count).put("t", trip)
                    votes.put(m, entry)
                    prefs(context).edit()
                        .putString(obf(RAW_KEY_CANDIDATE_VOTES), votes.toString())
                        .apply()
                }

                if (count >= DISTINCT_TRIPS_TO_LEARN) {
                    setLearnedCar(context, m, name ?: "내 차")
                    // 학습 완료 → 진행용 상태 정리(스테일 항목 누적·추후 오학습 방지).
                    prefs(context).edit()
                        .remove(obf(RAW_KEY_CANDIDATE_VOTES))
                        .remove(obf(RAW_KEY_CONNECTED))
                        .remove(obf(RAW_KEY_DRIVEN_CYCLE))
                        .apply()
                    true
                } else {
                    false
                }
            }.getOrDefault(false)
        }
    }

    // ── JSON set/map 저장 헬퍼 ───────────────────────────────────────────────

    private fun readSet(context: Context, rawKey: String): MutableSet<String> {
        val raw = prefs(context).getString(obf(rawKey), null) ?: return mutableSetOf()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapTo(mutableSetOf()) { arr.getString(it) }
        }.getOrDefault(mutableSetOf())
    }

    private fun writeSet(context: Context, rawKey: String, set: Set<String>) {
        val arr = JSONArray().apply { set.forEach { put(it) } }
        prefs(context).edit().putString(obf(rawKey), arr.toString()).apply()
    }

    private fun readVotes(context: Context): JSONObject {
        val raw = prefs(context).getString(obf(RAW_KEY_CANDIDATE_VOTES), null)
            ?: return JSONObject()
        return runCatching { JSONObject(raw) }.getOrDefault(JSONObject())
    }

    // ── 마이그레이션 ─────────────────────────────────────────────────────────

    /**
     * 레거시 평문 SharedPreferences(`FlutterSharedPreferences`) 에 저장돼 있던
     * `manual_car_id`, `manual_car_id_name` 값을 암호화 저장소로 옮기고,
     * 원본 평문 키를 안전하게 삭제한다.
     *
     * ## 동작 보장
     * - 이미 암호화 저장소에 MAC 이 있으면 **덮어쓰지 않는다** (사용자의 최신 선택 보호).
     * - 레거시에 값이 없으면 아무 것도 하지 않는다 (idempotent).
     * - 마이그레이션 성공 여부와 무관하게 평문 키는 삭제 시도한다 (Defense-in-depth).
     *
     * ## 호출 시점
     * [MainActivity.onCreate] — 앱이 실행될 때마다 한 번 호출되지만,
     * 레거시 키가 이미 지워진 상태라면 실질 비용은 O(1) 읽기 한 번.
     */
    fun migrateFromLegacy(context: Context) {
        runCatching {
            val legacy = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE,
            )
            val legacyMac = legacy.getString("flutter.manual_car_id", null)
            val legacyName = legacy.getString("flutter.manual_car_id_name", null)

            // 레거시 평문이 존재하고, 암호화 저장소가 비어있을 때만 이관.
            if (!legacyMac.isNullOrBlank() && getManualCarId(context) == null) {
                setManualCar(context, legacyMac, legacyName ?: "(이름 없음)")
            }

            // 레거시 평문은 어떤 경우든 제거한다 (At-Rest 위험 최소화).
            if (legacy.contains("flutter.manual_car_id") ||
                legacy.contains("flutter.manual_car_id_name")) {
                legacy.edit()
                    .remove("flutter.manual_car_id")
                    .remove("flutter.manual_car_id_name")
                    .apply()
            }
        }
    }
}
