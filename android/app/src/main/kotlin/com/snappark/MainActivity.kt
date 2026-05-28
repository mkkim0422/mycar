package com.snappark

import android.appwidget.AppWidgetManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import com.snappark.core.data.SecurePrefsHelper
import com.snappark.core.data.SharedPrefsHelper
import com.snappark.core.data.WidgetDisplayType
import com.snappark.core.receiver.BluetoothDisconnectReceiver
import com.snappark.core.service.MotionDetectionService
import com.snappark.core.widget.ParkingWidget2x1Provider
import com.snappark.core.widget.ParkingWidget2x2Provider
import com.snappark.core.widget.ParkingWidget4x2Provider
import com.snappark.core.widget.ParkingWidget4x4Provider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * SnapPark 앱의 메인 진입점.
 *
 * ## MethodChannel: "com.snappark/widget"
 * - Dart → Native:
 *     · "refreshWidget"                            → 설치된 모든 위젯 즉시 재그리기
 *     · "pinWidget"  {"size": "2x1|2x2|4x2|4x4"}   → OS에 홈 화면 고정 요청 (Android 8+)
 * - Native → Dart:
 *     · "onPayload"  → 위젯/BT 알림 탭 payload 전파 → Dart [NotificationService] 가 /camera 로 라우팅
 */
class MainActivity : FlutterActivity() {

    private val widgetChannel = "com.snappark/widget"
    private var channel: MethodChannel? = null

    // 콜드 스타트 시 엔진이 준비되기 전에 도착한 payload를 보관했다가
    // configureFlutterEngine 완료 시점에 Dart로 밀어 넣는다.
    private var pendingPayload: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingPayload = intent?.getStringExtra(BluetoothDisconnectReceiver.EXTRA_PAYLOAD)

        // ── 레거시 평문 MAC → 암호화 저장소 1회성 마이그레이션 ─────────────
        //    앱 실행마다 호출되지만, 레거시 키가 이미 제거된 상태라면 거의 no-op.
        //    Dart 초기화보다 먼저 실행되어야 이후 secureGetManualCarId 호출이 일관됨.
        SecurePrefsHelper.migrateFromLegacy(this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = intent.getStringExtra(BluetoothDisconnectReceiver.EXTRA_PAYLOAD)
        if (payload != null) {
            channel?.invokeMethod("onPayload", payload)
                ?: run { pendingPayload = payload }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, widgetChannel).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "refreshWidget" -> {
                        refreshAllWidgets()
                        result.success(null)
                    }
                    "pinWidget" -> {
                        val size = call.argument<String>("size") ?: "2x2"
                        val style = call.argument<String>("style") ?: "photo_info"
                        val outcome = requestPinWidget(size, style)
                        result.success(outcome)
                    }
                    "testMotionTrigger" -> {
                        // 테스트용: BT 연결 해제를 시뮬레이션하여 모션 감지 서비스 시작
                        val serviceIntent = Intent(this@MainActivity, MotionDetectionService::class.java)
                        runCatching {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(serviceIntent)
                            } else {
                                startService(serviceIntent)
                            }
                        }
                        result.success(null)
                    }
                    "getPairedDevices" -> {
                        // 이미 페어링된 BT 기기 목록만 반환한다 (스캔·새 연결 없음).
                        // 사용자가 '내 차' 태깅 대상을 선택하는 바텀시트에 쓰인다.
                        result.success(getPairedDevices())
                    }

                    "moveAppToBackground" -> {
                        // 위젯 pin 요청 직후 호출된다. 앱을 홈 화면으로 내려
                        // (finish 하지 않음) 사용자가 시스템 "홈 화면에 추가" 팝업을
                        // 확인하거나 추가된 위젯을 드래그할 수 있도록 한다.
                        runOnUiThread { moveTaskToBack(true) }
                        result.success(null)
                    }

                    // ── SecurePrefs 엔드포인트 (At-Rest 암호화 MAC 저장소) ─────
                    "secureSetManualCar" -> {
                        val mac = call.argument<String>("mac")
                        val name = call.argument<String>("name") ?: "(이름 없음)"
                        if (mac.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "mac is required", null)
                        } else {
                            SecurePrefsHelper.setManualCar(this@MainActivity, mac, name)
                            result.success(null)
                        }
                    }
                    "secureGetManualCar" -> {
                        val mac = SecurePrefsHelper.getManualCarId(this@MainActivity)
                        if (mac == null) {
                            result.success(null)
                        } else {
                            val name = SecurePrefsHelper.getManualCarName(this@MainActivity)
                                ?: "(이름 없음)"
                            result.success(mapOf("mac" to mac, "name" to name))
                        }
                    }
                    "secureClearManualCar" -> {
                        SecurePrefsHelper.clearManualCar(this@MainActivity)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
        }

        // 콜드 스타트 payload 전달
        pendingPayload?.let {
            channel?.invokeMethod("onPayload", it)
            pendingPayload = null
        }
    }

    /**
     * 시스템에 이미 **페어링(Bonded)된** 블루투스 기기 목록을 반환한다.
     *
     * ## 사용 용도
     * 설정 화면의 '알림이 오지 않나요?(수동 설정)' 바텀시트에서 사용자가 '내 차'로
     * 태깅할 기기를 고르는 용도. 태깅된 MAC 은 `manual_car_id` 키로 저장되어
     * [BluetoothDisconnectReceiver.isCarDevice] 의 0단계 바이패스에 사용된다.
     *
     * ## 중복 연결 가드
     * - 이 메서드는 `BluetoothAdapter.bondedDevices` 만 조회한다.
     * - `startDiscovery()`, `connectGatt()` 등 **새 연결을 시도하는 API 를 호출하지 않는다.**
     * - OS 이벤트를 필터링하는 태깅 정보 수집 외에 부수 효과 없음.
     *
     * ## 권한
     * - API 31+: `BLUETOOTH_CONNECT` 런타임 권한 필요 → 없으면 빈 리스트 반환.
     * - API 30-: Manifest 선언만으로 충분.
     *
     * @return `[{"name": "Galaxy S24", "address": "AA:BB:..."}, ...]`
     */
    private fun getPairedDevices(): List<Map<String, String>> {
        // 권한 체크 (Android 12+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val granted = ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.BLUETOOTH_CONNECT,
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) return emptyList()
        }

        val adapter: BluetoothAdapter? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        } else {
            @Suppress("DEPRECATION")
            BluetoothAdapter.getDefaultAdapter()
        }
        if (adapter == null || !adapter.isEnabled) return emptyList()

        return runCatching {
            adapter.bondedDevices.orEmpty().mapNotNull { dev ->
                val addr = dev.address ?: return@mapNotNull null
                val name = runCatching { dev.name }.getOrNull() ?: "(이름 없음)"
                mapOf("name" to name, "address" to addr)
            }
        }.getOrDefault(emptyList())
    }

    /**
     * 모든 위젯 Provider 각각에 APPWIDGET_UPDATE 브로드캐스트를 전송한다.
     * Provider의 onUpdate가 호출되어 SharedPreferences에서 최신 데이터/설정을 읽는다.
     */
    private fun refreshAllWidgets() {
        val manager = AppWidgetManager.getInstance(this)

        listOf(
            ParkingWidget2x1Provider::class.java,
            ParkingWidget2x2Provider::class.java,
            ParkingWidget4x2Provider::class.java,
            ParkingWidget4x4Provider::class.java,
        ).forEach { providerClass ->
            val ids = manager.getAppWidgetIds(ComponentName(this, providerClass))
            if (ids.isNotEmpty()) {
                sendBroadcast(
                    Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE).apply {
                        component = ComponentName(this@MainActivity, providerClass)
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                    }
                )
            }
        }
    }

    /**
     * OS 런처에 "이 위젯을 홈 화면에 고정" 프롬프트를 요청한다 (Android 8.0+).
     *
     * [style] 에 따라 RemoteViews 프리뷰를 구성해 `EXTRA_APPWIDGET_PREVIEW` 로 전달한다.
     * 이렇게 하면 Samsung One UI 런처의 프리뷰가 앱 내 샘플과 동일한 데이터/스타일로
     * 표시되어 UX 가 통일된다.
     *
     * ## 반환값 (Dart 측에서 상태 안내용)
     * - "requested"    : 런처가 프롬프트를 표시했다. 사용자 수락/거부는 별개.
     * - "unsupported"  : Android 8 미만이거나 현재 런처가 pin API 미지원.
     * - "error"        : 예외 발생.
     */
    private fun requestPinWidget(size: String, style: String): String {
        val providerClass = when (size) {
            "2x1" -> ParkingWidget2x1Provider::class.java
            "2x2" -> ParkingWidget2x2Provider::class.java
            "4x2" -> ParkingWidget4x2Provider::class.java
            "4x4" -> ParkingWidget4x4Provider::class.java
            else -> ParkingWidget2x2Provider::class.java
        }
        val layoutId = when (size) {
            "2x1" -> com.snappark.R.layout.widget_2x1
            "2x2" -> com.snappark.R.layout.widget_2x2
            "4x2" -> com.snappark.R.layout.widget_4x2
            "4x4" -> com.snappark.R.layout.widget_4x4
            else -> com.snappark.R.layout.widget_2x2
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return "unsupported"

        return try {
            val manager = AppWidgetManager.getInstance(this)
            if (!manager.isRequestPinAppWidgetSupported) return "unsupported"

            val component = ComponentName(this, providerClass)

            // ── pin 브리지 기록 (per-widget 귀속용) ─────────────────────────
            // pin 직전 현재 존재하는 widgetId 를 모두 수집해 pending 과 함께 저장한다.
            // onUpdate 에서 "이 집합에 없는 widgetId" 만 pending 을 흡수 → 기존 위젯
            // 덮어쓰기를 원천 차단.
            val currentIds = listOf(
                ParkingWidget2x1Provider::class.java,
                ParkingWidget2x2Provider::class.java,
                ParkingWidget4x2Provider::class.java,
                ParkingWidget4x4Provider::class.java,
            ).flatMap { cls ->
                manager.getAppWidgetIds(ComponentName(this, cls)).toList()
            }.toSet()

            val styleEnum = when (style) {
                "photo_only" -> WidgetDisplayType.PHOTO_ONLY
                "info_only" -> WidgetDisplayType.INFO_ONLY
                else -> WidgetDisplayType.PHOTO_INFO
            }
            // INFO_ONLY 일 때만 현재 선택된 배경색을 함께 귀속
            val bgHex = if (styleEnum == WidgetDisplayType.INFO_ONLY) {
                getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    .getString("flutter.widget_info_bg_color", null)
            } else null

            SharedPrefsHelper.setPendingPin(this, styleEnum, bgHex, currentIds)

            // 현재 선택된 스타일을 반영한 RemoteViews 프리뷰 구성
            val previewViews = buildPreviewRemoteViews(layoutId, size, style)
            val extras = Bundle().apply {
                putParcelable(AppWidgetManager.EXTRA_APPWIDGET_PREVIEW, previewViews)
            }

            manager.requestPinAppWidget(component, extras, null)
            "requested"
        } catch (e: Exception) {
            // 릴리스 빌드에서는 ProGuard가 로그를 제거한다
            "error"
        }
    }

    /**
     * Samsung 런처 "홈 화면에 추가" 프롬프트에서 사용할 프리뷰 RemoteViews 를 구성한다.
     *
     * 앱 내 위젯 설정 페이지의 샘플과 **동일한** 텍스트·사진·색상이 보이도록 구성한다.
     * - 텍스트: 사이즈별 정보 계층과 동일 (headline + timestamp + address)
     * - 사진: Flutter assets 의 sample_parking.jpg 를 디코딩하여 주입
     * - 색상: info_only 일 때 사용자가 선택한 배경색 + 가독성 텍스트색 적용
     */
    private fun buildPreviewRemoteViews(
        layoutId: Int,
        size: String,
        style: String,
    ): RemoteViews {
        val views = RemoteViews(packageName, layoutId)

        // ── 텍스트: 앱 내 샘플과 동일 문구 ────────────────────────────────
        val headline = "지하 1층 · 22구역"
        runCatching { views.setTextViewText(R.id.tv_zone, headline) }

        val timestamp = when (size) {
            "2x1" -> "4/18(금) 오후 12:15"
            "2x2" -> "4/18(금) 오후 12:15"
            else -> "4월 18일(금) 오후 12:15 · 주차 후 32분 경과"
        }
        runCatching { views.setTextViewText(R.id.tv_timestamp, timestamp) }

        // 4x2 / 4x4: 주소
        if (size == "4x2" || size == "4x4") {
            runCatching {
                views.setTextViewText(R.id.tv_address, "서울 강남구 테헤란로")
                views.setViewVisibility(R.id.tv_address, View.VISIBLE)
            }
        }

        // 빈 상태 숨김, 데이터 상태 활성화
        views.setViewVisibility(R.id.ll_empty, View.GONE)
        views.setViewVisibility(R.id.ll_data, View.VISIBLE)

        when (style) {
            "photo_only" -> {
                loadSamplePhoto()?.let { views.setImageViewBitmap(R.id.iv_photo, it) }
                views.setViewVisibility(R.id.iv_photo, View.VISIBLE)
                views.setViewVisibility(R.id.view_shadow, View.GONE)
                views.setViewVisibility(R.id.ll_data, View.GONE)
            }
            "info_only" -> {
                views.setViewVisibility(R.id.iv_photo, View.GONE)
                views.setViewVisibility(R.id.view_shadow, View.GONE)
                // 사용자 선택 배경색 + 가독성 텍스트색
                val bgColor = SharedPrefsHelper.getWidgetInfoBgColor(this)
                views.setInt(R.id.widget_root, "setBackgroundColor", bgColor)
                val textColor = SharedPrefsHelper.getTextColorForBg(bgColor)
                val subColor = (textColor and 0x00FFFFFF) or (0xD9 shl 24)
                runCatching { views.setTextColor(R.id.tv_zone, textColor) }
                runCatching { views.setTextColor(R.id.tv_timestamp, subColor) }
                runCatching { views.setTextColor(R.id.tv_address, subColor) }
            }
            else -> {
                // photo_info (기본)
                loadSamplePhoto()?.let { views.setImageViewBitmap(R.id.iv_photo, it) }
                views.setViewVisibility(R.id.iv_photo, View.VISIBLE)
                views.setViewVisibility(R.id.view_shadow, View.VISIBLE)
            }
        }

        return views
    }

    /**
     * Flutter 번들 assets 에서 샘플 주차 사진을 다운샘플링하여 로드한다.
     * RemoteViews Parcel 크기 제한(~1MB)에 맞추기 위해 최대 400px 으로 축소.
     */
    private fun loadSamplePhoto(maxPx: Int = 400): android.graphics.Bitmap? = runCatching {
        val bytes = assets.open("flutter_assets/assets/images/sample_parking.jpg")
            .use { it.readBytes() }

        // 크기 측정
        val measure = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, measure)

        // 다운샘플링 비율
        var sample = 1
        while ((measure.outWidth / (sample * 2)) > maxPx &&
               (measure.outHeight / (sample * 2)) > maxPx) {
            sample *= 2
        }

        BitmapFactory.decodeByteArray(
            bytes, 0, bytes.size,
            BitmapFactory.Options().apply { inSampleSize = sample },
        )
    }.getOrNull()
}
