package com.snappark.core.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.view.View
import android.widget.RemoteViews
import androidx.exifinterface.media.ExifInterface
import com.snappark.MainActivity
import com.snappark.R
import com.snappark.core.data.ParkingDataSnapshot
import com.snappark.core.data.SharedPrefsHelper
import com.snappark.core.data.WidgetDisplayType
import com.snappark.core.receiver.BluetoothDisconnectReceiver
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// ══════════════════════════════════════════════════════════════════════════════
// 공유 헬퍼 함수
// ══════════════════════════════════════════════════════════════════════════════

private fun openAppPendingIntent(context: Context, openCamera: Boolean = false): PendingIntent {
    val payload = if (openCamera) {
        BluetoothDisconnectReceiver.PAYLOAD_OPEN_CAMERA
    } else {
        "go_home"
    }
    val intent = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra(BluetoothDisconnectReceiver.EXTRA_PAYLOAD, payload)
    }
    val requestCode = if (openCamera) 1 else 0
    return PendingIntent.getActivity(
        context, requestCode, intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun loadScaledBitmap(path: String, maxPx: Int = 800): Bitmap? = runCatching {
    val measure = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, measure)

    var sample = 1
    val w = measure.outWidth
    val h = measure.outHeight
    while ((w / (sample * 2)) > maxPx && (h / (sample * 2)) > maxPx) {
        sample *= 2
    }

    val decoded = BitmapFactory.decodeFile(
        path, BitmapFactory.Options().apply { inSampleSize = sample }
    ) ?: return@runCatching null

    applyExifRotation(path, decoded)
}.getOrNull()

private fun applyExifRotation(path: String, source: Bitmap): Bitmap {
    val orientation = runCatching {
        ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )
    }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)

    val matrix = Matrix()
    when (orientation) {
        ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
        ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
        ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
        ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
        ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
        ExifInterface.ORIENTATION_TRANSPOSE -> {
            matrix.postRotate(90f); matrix.postScale(-1f, 1f)
        }
        ExifInterface.ORIENTATION_TRANSVERSE -> {
            matrix.postRotate(270f); matrix.postScale(-1f, 1f)
        }
        else -> return source
    }

    return try {
        val rotated = Bitmap.createBitmap(
            source, 0, 0, source.width, source.height, matrix, true,
        )
        if (rotated != source) source.recycle()
        rotated
    } catch (oom: OutOfMemoryError) {
        source
    }
}

private fun parseIsoTimestamp(isoString: String): Date? = runCatching {
    val trimmed = if (isoString.contains('.')) isoString.substringBefore('.') else isoString
    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.KOREA).parse(trimmed)
}.getOrNull()

private val WEEKDAYS = arrayOf("일", "월", "화", "수", "목", "금", "토")

/** 요일 문자열 반환. */
private fun dayOfWeek(cal: Calendar): String =
    WEEKDAYS[cal.get(Calendar.DAY_OF_WEEK) - 1]

/** 시:분 + 오전/오후 포맷. */
private fun formatTime(cal: Calendar): String {
    val hour24 = cal.get(Calendar.HOUR_OF_DAY)
    val ampm = if (hour24 < 12) "오전" else "오후"
    val hour12 = when {
        hour24 == 0 -> 12
        hour24 > 12 -> hour24 - 12
        else -> hour24
    }
    val min = cal.get(Calendar.MINUTE).toString().padStart(2, '0')
    return "$ampm $hour12:$min"
}

/**
 * 2x1용 — 축약형: "4/17(목) 오후 3:22"
 */
private fun formatDateCompact(isoString: String): String {
    val date = parseIsoTimestamp(isoString) ?: return ""
    val cal = Calendar.getInstance().apply { time = date }
    val month = cal.get(Calendar.MONTH) + 1
    val day = cal.get(Calendar.DAY_OF_MONTH)
    val dow = dayOfWeek(cal)
    val time = formatTime(cal)
    return "$month/$day($dow) $time"
}

/**
 * 2x2용 — 축약 날짜 + 시간: "4/17(목) 오후 3:22"
 */
private fun formatDateMedium(isoString: String): String = formatDateCompact(isoString)

/**
 * 4x2/4x4용 — 전체 날짜 + 시간: "4월 17일(목) 오후 3:22"
 */
private fun formatDateFull(isoString: String): String {
    val date = parseIsoTimestamp(isoString) ?: return ""
    val cal = Calendar.getInstance().apply { time = date }
    val month = cal.get(Calendar.MONTH) + 1
    val day = cal.get(Calendar.DAY_OF_MONTH)
    val dow = dayOfWeek(cal)
    val time = formatTime(cal)
    return "${month}월 ${day}일($dow) $time"
}

/**
 * 주차 시각 이후 경과 시간을 자연어로 표기.
 * - 3분 미만: "방금전"
 * - 3~59분: "주차 후 #분 경과"
 * - 60분 이상: "주차 후 #시간##분 경과"
 */
private fun formatElapsed(isoString: String): String {
    val date = parseIsoTimestamp(isoString) ?: return ""
    val elapsedMillis = System.currentTimeMillis() - date.time
    if (elapsedMillis < 0) return ""
    val totalMin = elapsedMillis / 60_000
    if (totalMin < 3) return "방금전"
    val hours = totalMin / 60
    val mins = totalMin % 60
    if (hours < 1) return "주차 후 ${totalMin}분 경과"
    return if (mins == 0L) "주차 후 ${hours}시간 경과"
    else "주차 후 ${hours}시간 ${mins}분 경과"
}

private fun formatZone(raw: String): String {
    val trimmed = raw.trim()
    if (trimmed.isEmpty() || trimmed == "-") return trimmed
    if (trimmed.endsWith("구역")) return trimmed
    return "${trimmed}구역"
}

private fun composeHeadline(floor: String, zone: String): String {
    val showFloor = floor.isNotBlank() && floor != "-"
    val showZone = zone.isNotBlank() && zone != "-"
    val zoneText = if (showZone) formatZone(zone) else ""
    return when {
        showFloor && showZone -> "$floor · $zoneText"
        showFloor -> floor
        showZone -> zoneText
        else -> ""  // 층·구역 모두 비어있으면 빈 문자열 (tv_zone 숨김 처리)
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// 위젯 RemoteViews 바인딩 핵심 로직
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 위젯 사이즈별 정보 표기 상세 레벨.
 *
 * - 2x1: 층+구역 + 주차시간
 * - 2x2: 층+구역 + 주차시간 + 경과(방금전/##분 전 주차/…)
 * - 4x2: 2x2 + 주소
 * - 4x4: 4x2와 동일
 */
private enum class InfoDetail {
    ZONE_WITH_TIME,           // 2x1
    ZONE_TIME_ELAPSED,        // 2x2
    ZONE_TIME_ELAPSED_ADDR,   // 4x2, 4x4
}

private fun updateWidget(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetId: Int,
    layoutId: Int,
    detail: InfoDetail,
) {
    // 0) pending pin 값 흡수 — pin 직전 없던 widgetId(= 이번에 새로 생긴 것) 에 한해
    //    사용자가 선택한 스타일/배경색을 per-widget 키로 귀속시킨다.
    //    기존 위젯들은 knownIds 집합에 포함되므로 여기서 pending 을 소비하지 않아,
    //    각자 저장된 per-widget 스타일이 그대로 유지된다.
    SharedPrefsHelper.adoptPendingPinIfNew(context, appWidgetId)

    val snapshot = SharedPrefsHelper.getParkingData(context)
    val displayType = SharedPrefsHelper.getWidgetDisplayType(context, appWidgetId)
    val views = RemoteViews(context.packageName, layoutId)

    if (snapshot == null) {
        views.setViewVisibility(R.id.ll_empty, View.VISIBLE)
        views.setViewVisibility(R.id.ll_data, View.GONE)
        views.setViewVisibility(R.id.iv_photo, View.GONE)
        views.setViewVisibility(R.id.view_shadow, View.GONE)
    } else {
        bindDataState(context, views, snapshot, displayType, detail)
    }

    // INFO_ONLY 모드: per-widget 배경색 + 가독성 텍스트색 적용
    if (displayType == WidgetDisplayType.INFO_ONLY) {
        applyInfoOnlyColors(context, views, snapshot == null, appWidgetId)
    }

    views.setOnClickPendingIntent(
        R.id.widget_root,
        openAppPendingIntent(context, openCamera = snapshot == null),
    )

    appWidgetManager.updateAppWidget(appWidgetId, views)
}

private fun bindDataState(
    context: Context,
    views: RemoteViews,
    snapshot: ParkingDataSnapshot,
    displayType: WidgetDisplayType,
    detail: InfoDetail,
) {
    val bitmap = snapshot.photoPath?.let { loadScaledBitmap(it) }
    val photoAvailable = bitmap != null

    val headline = composeHeadline(snapshot.floor, snapshot.zone)
    views.setTextViewText(R.id.tv_zone, headline)
    // 층·구역이 비어있으면 tv_zone 자체를 숨김 (타임스탬프만 표시)
    views.setViewVisibility(
        R.id.tv_zone,
        if (headline.isNotEmpty()) View.VISIBLE else View.GONE,
    )
    bindDetailLine(views, snapshot, detail)

    views.setViewVisibility(R.id.ll_empty, View.GONE)

    // 사진이 필요한 모드인데 파일이 없으면 INFO_ONLY 로 폴백.
    // PHOTO_INFO 에서 층/구역이 비어있어도 타임스탬프는 항상 표시해야 하므로
    // PHOTO_ONLY 로 폴백하지 않는다.
    val effectiveType = when {
        (displayType == WidgetDisplayType.PHOTO_ONLY ||
         displayType == WidgetDisplayType.PHOTO_INFO) && !photoAvailable ->
            WidgetDisplayType.INFO_ONLY
        else -> displayType
    }

    // ll_data 의 풀스크린 반투명 배경을 제거했으므로, PHOTO_INFO 모드에서는
    // 하단 그라디언트 쉐도우(view_shadow) 를 다시 켜서 밝은 사진 위에서도
    // 텍스트 가독성을 확보한다. INFO_ONLY / PHOTO_ONLY 에서는 불필요.
    when (effectiveType) {
        WidgetDisplayType.PHOTO_ONLY -> {
            views.setViewVisibility(R.id.iv_photo, View.VISIBLE)
            views.setImageViewBitmap(R.id.iv_photo, bitmap)
            views.setViewVisibility(R.id.ll_data, View.GONE)
            views.setViewVisibility(R.id.view_shadow, View.GONE)
        }
        WidgetDisplayType.INFO_ONLY -> {
            views.setViewVisibility(R.id.iv_photo, View.GONE)
            views.setViewVisibility(R.id.ll_data, View.VISIBLE)
            views.setViewVisibility(R.id.view_shadow, View.GONE)
        }
        WidgetDisplayType.PHOTO_INFO -> {
            views.setViewVisibility(R.id.iv_photo, View.VISIBLE)
            views.setImageViewBitmap(R.id.iv_photo, bitmap)
            views.setViewVisibility(R.id.ll_data, View.VISIBLE)
            views.setViewVisibility(R.id.view_shadow, View.VISIBLE)
        }
    }
}

/**
 * 사이즈별 보조 정보 텍스트를 바인딩한다.
 *
 * - ZONE_WITH_TIME (2x1):  "4/17(목) 오후 3:22"
 * - ZONE_TIME_ELAPSED (2x2): "4/17(목) 오후 3:22 · 주차 후 32분 경과"
 * - ZONE_TIME_ELAPSED_ADDR (4x2/4x4): "4월 17일(목) 오후 3:22 · 주차 후 32분 경과" + 주소
 */
private fun bindDetailLine(
    views: RemoteViews,
    snapshot: ParkingDataSnapshot,
    detail: InfoDetail,
) {
    val timestamp = when (detail) {
        InfoDetail.ZONE_WITH_TIME -> {
            // 2x1: 날짜+요일+시간만 (공간 제한)
            formatDateCompact(snapshot.timestamp)
        }
        InfoDetail.ZONE_TIME_ELAPSED -> {
            // 2x2: 날짜+요일+시간 + 경과
            val dateTime = formatDateMedium(snapshot.timestamp)
            val elapsed = formatElapsed(snapshot.timestamp)
            listOf(dateTime, elapsed).filter { it.isNotEmpty() }.joinToString(" · ")
        }
        InfoDetail.ZONE_TIME_ELAPSED_ADDR -> {
            // 4x2/4x4: 전체 날짜+요일+시간 + 경과
            val dateTime = formatDateFull(snapshot.timestamp)
            val elapsed = formatElapsed(snapshot.timestamp)
            listOf(dateTime, elapsed).filter { it.isNotEmpty() }.joinToString(" · ")
        }
    }
    runCatching { views.setTextViewText(R.id.tv_timestamp, timestamp) }

    // 주소 바인딩 (4x2, 4x4 레이아웃에만 tv_address 가 존재)
    if (detail == InfoDetail.ZONE_TIME_ELAPSED_ADDR) {
        val addr = snapshot.address?.takeIf { it.isNotBlank() } ?: ""
        runCatching { views.setTextViewText(R.id.tv_address, addr) }
        runCatching {
            views.setViewVisibility(
                R.id.tv_address,
                if (addr.isNotEmpty()) View.VISIBLE else View.GONE,
            )
        }
    }
}

/**
 * INFO_ONLY 모드 전용: widgetId 별 배경색을 적용하고
 * 밝기 기반으로 텍스트 색상을 가독성 있게 설정한다.
 */
private fun applyInfoOnlyColors(
    context: Context,
    views: RemoteViews,
    isEmpty: Boolean,
    appWidgetId: Int,
) {
    val bgColor = SharedPrefsHelper.getWidgetInfoBgColor(context, appWidgetId)
    views.setInt(R.id.widget_root, "setBackgroundColor", bgColor)

    val textColor = SharedPrefsHelper.getTextColorForBg(bgColor)
    val subAlpha = 0xD9 // 85%
    val subColor = (textColor and 0x00FFFFFF) or (subAlpha shl 24)

    if (isEmpty) {
        runCatching { views.setTextColor(R.id.tv_empty_text, textColor) }
        runCatching { views.setTextColor(R.id.tv_empty_sub, subColor) }
    } else {
        runCatching { views.setTextColor(R.id.tv_zone, textColor) }
        runCatching { views.setTextColor(R.id.tv_timestamp, subColor) }
        runCatching { views.setTextColor(R.id.tv_address, subColor) }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// 2×1 Provider — 구역 + 주차시간
// ══════════════════════════════════════════════════════════════════════════════

class ParkingWidget2x1Provider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { id ->
            kotlin.concurrent.thread(name = "widget-2x1-update") {
                updateWidget(
                    context, appWidgetManager, id,
                    layoutId = R.layout.widget_2x1,
                    detail = InfoDetail.ZONE_WITH_TIME,
                )
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { SharedPrefsHelper.removeWidgetSettings(context, it) }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// 2×2 Provider — 구역 + 주차시간 + 경과
// ══════════════════════════════════════════════════════════════════════════════

class ParkingWidget2x2Provider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { id ->
            kotlin.concurrent.thread(name = "widget-2x2-update") {
                updateWidget(
                    context, appWidgetManager, id,
                    layoutId = R.layout.widget_2x2,
                    detail = InfoDetail.ZONE_TIME_ELAPSED,
                )
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { SharedPrefsHelper.removeWidgetSettings(context, it) }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// 4×2 Provider — 구역 + 주차시간 + 경과 + 주소
// ══════════════════════════════════════════════════════════════════════════════

class ParkingWidget4x2Provider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { id ->
            kotlin.concurrent.thread(name = "widget-4x2-update") {
                updateWidget(
                    context, appWidgetManager, id,
                    layoutId = R.layout.widget_4x2,
                    detail = InfoDetail.ZONE_TIME_ELAPSED_ADDR,
                )
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { SharedPrefsHelper.removeWidgetSettings(context, it) }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// 4×4 Provider — 4x2와 동일 (구역 + 주차시간 + 경과 + 주소)
// ══════════════════════════════════════════════════════════════════════════════

class ParkingWidget4x4Provider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { id ->
            kotlin.concurrent.thread(name = "widget-4x4-update") {
                updateWidget(
                    context, appWidgetManager, id,
                    layoutId = R.layout.widget_4x4,
                    detail = InfoDetail.ZONE_TIME_ELAPSED_ADDR,
                )
            }
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { SharedPrefsHelper.removeWidgetSettings(context, it) }
    }
}
