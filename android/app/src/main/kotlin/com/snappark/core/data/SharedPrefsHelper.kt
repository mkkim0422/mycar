package com.snappark.core.data

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

/**
 * Flutter shared_preferences 패키지와 동일한 저장소에 접근하는 Android Native 헬퍼.
 *
 * Flutter shared_preferences 저장 규칙:
 *   - 파일명 : "FlutterSharedPreferences"
 *   - 모드   : Context.MODE_PRIVATE
 *   - 키 형식: "flutter.<dart_key>"
 *
 * → Flutter에서 prefs.setString('parking_data', jsonString) 으로 저장하면
 *   Android Native에서는 키 "flutter.parking_data"로 읽을 수 있다.
 *
 * AppWidgetProvider / AppWidgetService 등 네이티브 컴포넌트에서
 * [getParkingData]를 호출하면 Flutter 앱 없이도 즉시 데이터를 읽을 수 있다.
 */
object SharedPrefsHelper {

    /** Flutter shared_preferences 패키지가 사용하는 SharedPreferences 파일명 */
    private const val PREFS_FILE = "FlutterSharedPreferences"

    /** Flutter 키 접두사 */
    private const val KEY_PREFIX = "flutter."

    /** parking_data 키 (Flutter: 'parking_data') */
    private const val KEY_PARKING_DATA = "${KEY_PREFIX}parking_data"

    // ── JSON 필드명 (parking_data.dart의 toJson 키와 동일해야 한다) ──────────
    private const val FIELD_FLOOR = "floor"
    private const val FIELD_ZONE = "zone"
    private const val FIELD_PHOTO_PATH = "photoPath"
    private const val FIELD_TIMESTAMP = "timestamp"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /**
     * Flutter 앱이 저장한 주차 데이터를 읽어 [ParkingDataSnapshot]으로 반환한다.
     * 저장된 데이터가 없거나 파싱 실패 시 null 반환.
     */
    fun getParkingData(context: Context): ParkingDataSnapshot? {
        val raw = prefs(context).getString(KEY_PARKING_DATA, null) ?: return null
        return runCatching {
            val json = JSONObject(raw)
            ParkingDataSnapshot(
                floor = json.getString(FIELD_FLOOR),
                zone = json.getString(FIELD_ZONE),
                photoPath = if (json.isNull(FIELD_PHOTO_PATH)) null
                            else json.getString(FIELD_PHOTO_PATH),
                timestamp = json.getString(FIELD_TIMESTAMP),
            )
        }.getOrNull()
    }

    /**
     * 저장된 주차 데이터의 원시 JSON 문자열을 반환한다.
     * 위젯 갱신 시 직접 파싱이 필요한 경우 사용.
     */
    fun getRawJson(context: Context): String? =
        prefs(context).getString(KEY_PARKING_DATA, null)
}

/**
 * Android Native에서 사용하는 주차 데이터 스냅샷.
 * [parking_data.dart]의 ParkingData와 필드가 1:1 대응된다.
 *
 * @property floor     주차 층수 (예: "B2", "3F")
 * @property zone      주차 구역 (예: "A-04", "나-12")
 * @property photoPath 사진 로컬 경로 (없으면 null)
 * @property timestamp ISO 8601 형식 저장 시각 문자열
 */
data class ParkingDataSnapshot(
    val floor: String,
    val zone: String,
    val photoPath: String?,
    val timestamp: String,
)
