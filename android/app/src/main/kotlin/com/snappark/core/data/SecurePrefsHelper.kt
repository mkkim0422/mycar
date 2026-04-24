package com.snappark.core.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
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
    }

    /** 수동 태깅 해제. 암호화된 저장소의 키도 모두 제거. */
    fun clearManualCar(context: Context) {
        runCatching {
            prefs(context).edit()
                .remove(obf(RAW_KEY_CAR_MAC))
                .remove(obf(RAW_KEY_CAR_NAME))
                .apply()
        }
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
