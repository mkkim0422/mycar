package com.snappark.core.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.View
import android.widget.RemoteViews
import com.snappark.MainActivity
import com.snappark.R
import com.snappark.core.data.SharedPrefsHelper
import com.snappark.core.receiver.BluetoothDisconnectReceiver
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

// ══════════════════════════════════════════════════════════════════════════════
// 공유 헬퍼 함수
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 앱 실행 PendingIntent.
 *
 * @param openCamera true면 MainActivity 진입 후 카메라 화면으로 라우팅한다
 *                   (BluetoothDisconnectReceiver와 동일한 payload 재사용).
 *                   데이터가 없는 "빈 상태" 위젯 탭 시 사용.
 */
private fun openAppPendingIntent(context: Context, openCamera: Boolean = false): PendingIntent {
    val intent = Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        if (openCamera) {
            putExtra(
                BluetoothDisconnectReceiver.EXTRA_PAYLOAD,
                BluetoothDisconnectReceiver.PAYLOAD_OPEN_CAMERA,
            )
        }
    }
    // requestCode를 분리해야 FLAG_UPDATE_CURRENT가 두 PendingIntent를 구분한다.
    val requestCode = if (openCamera) 1 else 0
    return PendingIntent.getActivity(
        context, requestCode, intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

/**
 * 파일 경로에서 비트맵을 샘플링하여 로드한다.
 * maxPx 이상의 축을 2의 거듭제곱으로 다운샘플링하여 메모리를 절약한다.
 * 실패 시 null 반환.
 */
private fun loadScaledBitmap(path: String, maxPx: Int = 800): Bitmap? = runCatching {
    // 1단계: 실제 디코딩 없이 이미지 크기만 측정
    val measure = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(path, measure)

    // 2단계: 샘플 사이즈 계산 (maxPx 이하가 될 때까지 2배씩 축소)
    var sample = 1
    val w = measure.outWidth
    val h = measure.outHeight
    while ((w / (sample * 2)) > maxPx && (h / (sample * 2)) > maxPx) {
        sample *= 2
    }

    // 3단계: 실제 디코딩
    BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
}.getOrNull()

/**
 * ISO 8601 문자열을 한국어 주차 시간 형식으로 변환한다.
 * 예) "2025-04-14T15:22:00.000000" → "2025년 4월 14일 오후 3:22 주차"
 * 파싱 실패 시 원본 문자열을 그대로 반환.
 */
private fun formatTimestamp(isoString: String): String = runCatching {
    // Dart DateTime.toIso8601String() 형식: "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
    // SimpleDateFormat은 마이크로초를 지원하지 않으므로 초 단위까지만 파싱
    val trimmed = if (isoString.contains('.')) isoString.substringBefore('.') else isoString
    val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.KOREA)
    val date = fmt.parse(trimmed) ?: return@runCatching isoString

    val cal = Calendar.getInstance().apply { time = date }
    val hour24 = cal.get(Calendar.HOUR_OF_DAY)
    val ampm = if (hour24 < 12) "오전" else "오후"
    val hour12 = when {
        hour24 == 0 -> 12
        hour24 > 12 -> hour24 - 12
        else -> hour24
    }
    val min = cal.get(Calendar.MINUTE).toString().padStart(2, '0')
    val year = cal.get(Calendar.YEAR)
    val month = cal.get(Calendar.MONTH) + 1
    val day = cal.get(Calendar.DAY_OF_MONTH)
    "${year}년 ${month}월 ${day}일  $ampm $hour12:$min 주차"
}.getOrElse { isoString }

// ══════════════════════════════════════════════════════════════════════════════
// 위젯 RemoteViews 바인딩 핵심 로직
// ══════════════════════════════════════════════════════════════════════════════

/**
 * SharedPrefsHelper에서 데이터를 읽어 RemoteViews를 구성하고 위젯을 갱신한다.
 *
 * @param layoutId   R.layout.widget_2x1 / widget_2x2 / widget_4x4
 * @param hasPhoto   2x2·4x4는 true, 2x1은 false
 * @param hasTimestamp 4x4만 true
 */
private fun updateWidget(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetId: Int,
    layoutId: Int,
    hasPhoto: Boolean,
    hasTimestamp: Boolean,
) {
    val snapshot = SharedPrefsHelper.getParkingData(context)
    val views = RemoteViews(context.packageName, layoutId)

    if (snapshot == null) {
        // ── 빈 상태 ────────────────────────────────────────────────────────
        views.setViewVisibility(R.id.ll_empty, View.VISIBLE)
        views.setViewVisibility(R.id.ll_data, View.GONE)
        if (hasPhoto) {
            views.setViewVisibility(R.id.iv_photo, View.GONE)
            views.setViewVisibility(R.id.view_shadow, View.GONE)
        }
    } else {
        // ── 데이터 상태 ────────────────────────────────────────────────────
        views.setViewVisibility(R.id.ll_empty, View.GONE)
        views.setViewVisibility(R.id.ll_data, View.VISIBLE)

        // 구역 텍스트
        views.setTextViewText(R.id.tv_zone, snapshot.zone)

        // 사진 (2x2·4x4만)
        if (hasPhoto) {
            val bitmap = snapshot.photoPath?.let { loadScaledBitmap(it) }
            if (bitmap != null) {
                views.setViewVisibility(R.id.iv_photo, View.VISIBLE)
                views.setImageViewBitmap(R.id.iv_photo, bitmap)
                views.setViewVisibility(R.id.view_shadow, View.VISIBLE)
            } else {
                // 사진 파일 없음 → Toss Blue 배경(루트 bg)으로 폴백
                views.setViewVisibility(R.id.iv_photo, View.GONE)
                views.setViewVisibility(R.id.view_shadow, View.GONE)
            }
        }

        // 주차 시간 (4x4만)
        if (hasTimestamp) {
            views.setTextViewText(R.id.tv_timestamp, formatTimestamp(snapshot.timestamp))
        }
    }

    // 탭 → 빈 상태면 카메라로 직행, 데이터 있으면 홈으로.
    views.setOnClickPendingIntent(
        R.id.widget_root,
        openAppPendingIntent(context, openCamera = snapshot == null),
    )

    appWidgetManager.updateAppWidget(appWidgetId, views)
}

// ══════════════════════════════════════════════════════════════════════════════
// 2×1 Provider
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 2×1 미니멀 위젯.
 * Toss Blue 단색 배경 + 구역 텍스트만 표시. 사진 없음.
 */
class ParkingWidget2x1Provider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { id ->
            // 비트맵 로드가 없어 메인 스레드에서 직접 처리
            updateWidget(
                context, appWidgetManager, id,
                layoutId = R.layout.widget_2x1,
                hasPhoto = false,
                hasTimestamp = false,
            )
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// 2×2 Provider
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 2×2 정사각형 풀블리드 사진 위젯.
 * 하단 그라디언트 쉐도우 + 구역 텍스트 오버레이.
 * 비트맵 로드를 백그라운드 스레드에서 처리하여 ANR 방지.
 */
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
                    hasPhoto = true,
                    hasTimestamp = false,
                )
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// 4×4 Provider
// ══════════════════════════════════════════════════════════════════════════════

/**
 * 4×4 대형 풀블리드 사진 위젯.
 * 하단 그라디언트 쉐도우 + 구역 텍스트 + 주차 시간 오버레이.
 * 비트맵 로드를 백그라운드 스레드에서 처리하여 ANR 방지.
 */
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
                    hasPhoto = true,
                    hasTimestamp = true,
                )
            }
        }
    }
}
