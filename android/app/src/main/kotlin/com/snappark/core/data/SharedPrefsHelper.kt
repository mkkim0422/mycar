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

    /** 위젯 디스플레이 타입 키 (Flutter: 'widget_display_type') */
    private const val KEY_WIDGET_DISPLAY_TYPE = "${KEY_PREFIX}widget_display_type"


    /** 위치전용 모드 배경색 키 (Flutter: 'widget_info_bg_color') */
    private const val KEY_WIDGET_INFO_BG_COLOR = "${KEY_PREFIX}widget_info_bg_color"

    /**
     * 블루투스 자동 감지 토글 키 (Flutter: 'bt_auto_enabled').
     * false 면 [BluetoothDisconnectReceiver] 와 [MotionDetectionService] 가
     * 조기 return 해 어떤 알림도 발송하지 않는다.
     */
    private const val KEY_BT_AUTO_ENABLED = "${KEY_PREFIX}bt_auto_enabled"

    // 수동 태깅된 차량 BT MAC 은 이 파일이 아닌 [SecurePrefsHelper] (암호화 저장소)
    // 에서 관리한다. AndroidKeyStore 마스터 키로 보호되며, 레거시 평문 키는
    // MainActivity.onCreate 에서 SecurePrefsHelper.migrateFromLegacy() 가 이관/삭제.

    // ── Per-widget 저장 키 접두사 ─────────────────────────────────────────────
    //   appWidgetId 를 suffix 로 붙여 "위젯마다 독립된" 스타일/배경색을 저장한다.
    //   이 접두사 기반 키를 두는 이유: pin 당시 선택한 스타일이 다른 위젯에 의해
    //   덮어써지지 않도록 widgetId 별로 격리 저장하기 위함.
    private const val KEY_WIDGET_TYPE_PER_ID_PREFIX = "${KEY_PREFIX}widget_display_type_"
    private const val KEY_WIDGET_BG_PER_ID_PREFIX = "${KEY_PREFIX}widget_info_bg_color_"

    // ── pin 브리지 (requestPinAppWidget 과 onUpdate 사이의 전달) ──────────────
    //   - PENDING_PIN_STYLE : 사용자가 이번에 pin 하려 선택한 스타일
    //   - PENDING_PIN_BG    : 사용자가 이번에 pin 하려 선택한 배경색(hex)
    //   - PRE_PIN_KNOWN_IDS : pin 직전 이미 존재하던 widgetId 집합.
    //     onUpdate 브로드캐스트가 여러 widgetId 에 한꺼번에 도착해도, 이 집합에
    //     포함되지 않은 ID(= 이번에 새로 추가된 widget)만 pending 을 흡수한다.
    private const val KEY_PENDING_PIN_STYLE = "${KEY_PREFIX}pending_pin_style"
    private const val KEY_PENDING_PIN_BG = "${KEY_PREFIX}pending_pin_bg"
    private const val KEY_PRE_PIN_KNOWN_IDS = "${KEY_PREFIX}pre_pin_known_ids"

    // ── JSON 필드명 (parking_data.dart의 toJson 키와 동일해야 한다) ──────────
    private const val FIELD_FLOOR = "floor"
    private const val FIELD_ZONE = "zone"
    private const val FIELD_PHOTO_PATH = "photoPath"
    private const val FIELD_TIMESTAMP = "timestamp"
    private const val FIELD_LATITUDE = "latitude"
    private const val FIELD_LONGITUDE = "longitude"
    private const val FIELD_ADDRESS = "address"

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
                photoPath = json.optStringOrNull(FIELD_PHOTO_PATH),
                timestamp = json.getString(FIELD_TIMESTAMP),
                latitude = if (json.has(FIELD_LATITUDE) && !json.isNull(FIELD_LATITUDE))
                    json.getDouble(FIELD_LATITUDE) else null,
                longitude = if (json.has(FIELD_LONGITUDE) && !json.isNull(FIELD_LONGITUDE))
                    json.getDouble(FIELD_LONGITUDE) else null,
                address = json.optStringOrNull(FIELD_ADDRESS),
            )
        }.getOrNull()
    }

    /**
     * 저장된 주차 데이터의 원시 JSON 문자열을 반환한다.
     * 위젯 갱신 시 직접 파싱이 필요한 경우 사용.
     */
    fun getRawJson(context: Context): String? =
        prefs(context).getString(KEY_PARKING_DATA, null)

    /**
     * 사용자가 선택한 위젯 디스플레이 타입을 반환한다.
     * 저장된 값이 없거나 알 수 없는 값이면 [WidgetDisplayType.PHOTO_INFO] (기본) 반환.
     */
    fun getWidgetDisplayType(context: Context): WidgetDisplayType =
        WidgetDisplayType.fromKey(prefs(context).getString(KEY_WIDGET_DISPLAY_TYPE, null))

    /**
     * 블루투스 자동 감지 기능이 켜져 있는지 반환한다.
     * 키가 없는 기존 설치도 자동 감지를 기대하는 것이 자연스럽기 때문에 기본 true.
     * 사용자가 설정에서 OFF 로 바꾸면 false 가 저장되며, 이 값을 본 Receiver/Service 가
     * 알림 발송을 전면 차단한다.
     */
    fun isBtAutoEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_BT_AUTO_ENABLED, true)


    /**
     * 위치전용 모드에서 사용자가 선택한 배경색을 ARGB int 로 반환한다.
     * 저장된 값이 없거나 파싱 실패 시 기본 Toss Blue(0xFF0064FF) 반환.
     */
    fun getWidgetInfoBgColor(context: Context): Int {
        val hex = prefs(context).getString(KEY_WIDGET_INFO_BG_COLOR, null)
        return if (hex != null) {
            runCatching { android.graphics.Color.parseColor(hex) }.getOrDefault(0xFF0064FF.toInt())
        } else {
            0xFF0064FF.toInt()
        }
    }

    // ── Per-widget 스타일 · 배경색 ────────────────────────────────────────────

    /**
     * 특정 widgetId 에 per-widget 스타일이 저장되어 있는지 여부.
     * pending pin 값을 이중 흡수하지 않기 위한 가드로 쓰인다.
     */
    fun hasWidgetDisplayType(context: Context, widgetId: Int): Boolean =
        prefs(context).contains("$KEY_WIDGET_TYPE_PER_ID_PREFIX$widgetId")

    /**
     * widgetId 별 디스플레이 타입을 반환한다.
     * - per-widget 값이 있으면 그것을 우선 사용
     * - 없으면 전역 기본값([getWidgetDisplayType] 오버로드) 으로 fallback
     *
     * → 구(舊) 버전에서 추가된 per-widget 값이 없는 위젯은 기존처럼 전역을 따른다.
     */
    fun getWidgetDisplayType(context: Context, widgetId: Int): WidgetDisplayType {
        val perId = prefs(context).getString("$KEY_WIDGET_TYPE_PER_ID_PREFIX$widgetId", null)
        return if (perId != null) WidgetDisplayType.fromKey(perId)
        else getWidgetDisplayType(context)
    }

    fun setWidgetDisplayType(context: Context, widgetId: Int, type: WidgetDisplayType) {
        val key = when (type) {
            WidgetDisplayType.PHOTO_ONLY -> "photo_only"
            WidgetDisplayType.INFO_ONLY -> "info_only"
            WidgetDisplayType.PHOTO_INFO -> "photo_info"
        }
        prefs(context).edit()
            .putString("$KEY_WIDGET_TYPE_PER_ID_PREFIX$widgetId", key)
            .apply()
    }

    /**
     * widgetId 별 위치전용 배경색을 반환한다. per-widget 값이 없으면 전역 기본을 사용.
     */
    fun getWidgetInfoBgColor(context: Context, widgetId: Int): Int {
        val hex = prefs(context).getString("$KEY_WIDGET_BG_PER_ID_PREFIX$widgetId", null)
        return if (hex != null) {
            runCatching { android.graphics.Color.parseColor(hex) }
                .getOrDefault(0xFF0064FF.toInt())
        } else {
            getWidgetInfoBgColor(context)
        }
    }

    fun setWidgetInfoBgColorHex(context: Context, widgetId: Int, hex: String) {
        prefs(context).edit()
            .putString("$KEY_WIDGET_BG_PER_ID_PREFIX$widgetId", hex)
            .apply()
    }

    /**
     * 위젯이 홈 화면에서 삭제되면 per-widget 키를 정리한다.
     * [AppWidgetProvider.onDeleted] 에서 호출.
     */
    fun removeWidgetSettings(context: Context, widgetId: Int) {
        prefs(context).edit()
            .remove("$KEY_WIDGET_TYPE_PER_ID_PREFIX$widgetId")
            .remove("$KEY_WIDGET_BG_PER_ID_PREFIX$widgetId")
            .apply()
    }

    // ── pin 브리지 ───────────────────────────────────────────────────────────

    /**
     * `requestPinAppWidget` 호출 직전에 MainActivity 에서 호출한다.
     * 이번 pin 요청에 연결될 스타일/배경색과, pin 직전 이미 존재하던 widgetId 집합을
     * 함께 저장한다.
     *
     * @param knownWidgetIds pin 전에 이미 설치되어 있던 모든 widgetId (중복 흡수 방지용)
     */
    fun setPendingPin(
        context: Context,
        style: WidgetDisplayType,
        bgHex: String?,
        knownWidgetIds: Set<Int>,
    ) {
        val styleKey = when (style) {
            WidgetDisplayType.PHOTO_ONLY -> "photo_only"
            WidgetDisplayType.INFO_ONLY -> "info_only"
            WidgetDisplayType.PHOTO_INFO -> "photo_info"
        }
        val editor = prefs(context).edit()
            .putString(KEY_PENDING_PIN_STYLE, styleKey)
            .putStringSet(
                KEY_PRE_PIN_KNOWN_IDS,
                knownWidgetIds.map { it.toString() }.toSet(),
            )
        if (bgHex != null) editor.putString(KEY_PENDING_PIN_BG, bgHex)
        else editor.remove(KEY_PENDING_PIN_BG)
        editor.apply()
    }

    /**
     * onUpdate 시점에 호출 — 이 widgetId 가 pin 직전에 이미 존재하지 않았다면
     * (= 이번 pin 으로 새로 추가된 위젯) pending 값을 소비하여 per-widget 에 저장한다.
     *
     * 한 번 소비되면 pending/knownIds 를 즉시 제거하여 이후 widgetId 가 잘못
     * 흡수하는 일을 막는다.
     *
     * @return 적용된 스타일 (소비하지 않았으면 null)
     */
    fun adoptPendingPinIfNew(context: Context, widgetId: Int): WidgetDisplayType? {
        val p = prefs(context)
        val knownIdsRaw = p.getStringSet(KEY_PRE_PIN_KNOWN_IDS, null) ?: return null
        if (widgetId.toString() in knownIdsRaw) return null // 기존 위젯 → 소비하지 않음

        val styleRaw = p.getString(KEY_PENDING_PIN_STYLE, null) ?: return null
        val bgHex = p.getString(KEY_PENDING_PIN_BG, null)

        val style = WidgetDisplayType.fromKey(styleRaw)
        setWidgetDisplayType(context, widgetId, style)
        if (bgHex != null) setWidgetInfoBgColorHex(context, widgetId, bgHex)

        p.edit()
            .remove(KEY_PENDING_PIN_STYLE)
            .remove(KEY_PENDING_PIN_BG)
            .remove(KEY_PRE_PIN_KNOWN_IDS)
            .apply()
        return style
    }

    /**
     * 배경색의 밝기(luminance)에 따라 가독성 좋은 텍스트 색상을 반환한다.
     * 밝은 배경 → 어두운 텍스트(#1B1D21), 어두운 배경 → 흰색 텍스트.
     */
    fun getTextColorForBg(bgColor: Int): Int {
        val r = android.graphics.Color.red(bgColor) / 255.0
        val g = android.graphics.Color.green(bgColor) / 255.0
        val b = android.graphics.Color.blue(bgColor) / 255.0
        val luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return if (luminance > 0.55) 0xFF1B1D21.toInt() else 0xFFFFFFFF.toInt()
    }

    // ── JSON 편의 확장 ────────────────────────────────────────────────────
    // org.json.JSONObject.optString(key, fallback) 의 fallback 은 non-null 이라
    // `null` 을 넘길 수 없다. 빈 문자열 fallback 후 isEmpty 체크로 null 복원.
    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        val v = optString(key, "")
        return if (v.isEmpty()) null else v
    }
}

/**
 * Android Native에서 사용하는 주차 데이터 스냅샷.
 * [parking_data.dart]의 ParkingData와 필드가 1:1 대응된다.
 *
 * @property floor     주차 층수 (예: "지하 2층", "3F")
 * @property zone      주차 구역 (예: "A-04", "22")
 * @property photoPath 사진 로컬 경로 (없으면 null)
 * @property timestamp ISO 8601 형식 저장 시각 문자열
 * @property latitude  주차 지점 GPS 위도 (없으면 null)
 * @property longitude 주차 지점 GPS 경도 (없으면 null)
 * @property address   역지오코딩된 한국어 주소 (없으면 null)
 */
data class ParkingDataSnapshot(
    val floor: String,
    val zone: String,
    val photoPath: String?,
    val timestamp: String,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val address: String? = null,
)

/**
 * 위젯 디스플레이 타입. 사용자가 설정 페이지에서 선택한 값이 SharedPrefs에 저장된다.
 *
 * - [PHOTO_ONLY] : 사진만 풀블리드 (정보 텍스트 숨김)
 * - [INFO_ONLY]  : 파란 배경 + 정보 텍스트만 (사진 숨김)
 * - [PHOTO_INFO] : 풀블리드 사진 위에 정보 텍스트 오버레이 (기본, 첨부 스크린샷 스타일)
 */
enum class WidgetDisplayType {
    PHOTO_ONLY,
    INFO_ONLY,
    PHOTO_INFO;

    companion object {
        /** Flutter 측에서 저장한 문자열 키를 enum 값으로 매핑. 기본은 PHOTO_INFO. */
        fun fromKey(key: String?): WidgetDisplayType = when (key) {
            "photo_only" -> PHOTO_ONLY
            "info_only" -> INFO_ONLY
            // "photo_info" · null · 알 수 없는 값 모두 기본 PHOTO_INFO 로 귀결
            else -> PHOTO_INFO
        }
    }
}
