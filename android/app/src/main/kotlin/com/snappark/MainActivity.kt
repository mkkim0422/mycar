package com.snappark

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import com.snappark.core.receiver.BluetoothDisconnectReceiver
import com.snappark.core.widget.ParkingWidget2x1Provider
import com.snappark.core.widget.ParkingWidget2x2Provider
import com.snappark.core.widget.ParkingWidget4x4Provider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * SnapPark 앱의 메인 진입점.
 *
 * ## MethodChannel: "com.snappark/widget"
 * - Dart → Native: "refreshWidget" 호출 시 홈 위젯을 갱신한다.
 * - Native → Dart: "onPayload" 호출로 위젯/BT 알림 탭 시 전달된 payload를 전파한다.
 *   Dart 측 [NotificationService]가 이를 받아 `/camera`로 라우팅한다.
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
     * 3가지 위젯 Provider 각각에 APPWIDGET_UPDATE 브로드캐스트를 전송한다.
     * Provider의 onUpdate가 호출되어 SharedPreferences에서 최신 데이터를 읽는다.
     */
    private fun refreshAllWidgets() {
        val manager = AppWidgetManager.getInstance(this)

        listOf(
            ParkingWidget2x1Provider::class.java,
            ParkingWidget2x2Provider::class.java,
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
}
