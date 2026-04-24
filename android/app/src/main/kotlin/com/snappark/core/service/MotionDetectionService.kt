package com.snappark.core.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.snappark.MainActivity
import com.snappark.core.data.SharedPrefsHelper
import com.snappark.core.receiver.BluetoothDisconnectReceiver
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * BT/CarPlay 연결 해제 후 가속도계 기반 "하차 모션"을 감지하여
 * 최소 지연(< 3초)으로 주차 알림을 발송하는 경량 포그라운드 서비스.
 *
 * ## 동작 흐름
 * 1. [BluetoothDisconnectReceiver] 가 BT 해제 이벤트 수신 → 이 서비스 시작
 * 2. 가속도계 센서를 [SENSOR_DELAY_GAME](~50Hz)으로 등록
 * 3. 첫 [BASELINE_DURATION_MS](300ms) 동안 기준 가속도(magnitude) 수집
 * 4. 이후 매 샘플에서 |현재 mag − baseline| > [MOTION_THRESHOLD] 이면 **즉시** 알림
 * 5. [STILL_TIMEOUT_MS](10초)간 완전 정지 → "대기 모드" 진입, 다음 모션까지 보류
 * 6. [MAX_TIMEOUT_MS](2분) 도달 시 → 무조건 알림 (예: 폰을 차에 놓고 내린 경우)
 *
 * ## 배터리 영향
 * - 가속도계는 하드웨어 수준에서 매우 저전력 (~0.5mA)
 * - 서비스 수명 ≤ 2분 (대부분 1~3초 내 종료)
 * - Android 14+ `shortService` 타입 사용 → 3분 제한, 시스템 자원 최적화
 *
 * ## 알림 채널
 * - 포그라운드 서비스: `snappark_motion_channel` (LOW, 10초 내 종료 시 노출 안 됨)
 * - 주차 알림: `snappark_bt_channel` (HIGH, 진동 + 헤즈업 배너)
 */
class MotionDetectionService : Service(), SensorEventListener {

    companion object {
        // ── 포그라운드 서비스 알림 (임시, 저우선) ─────────────────────────
        private const val FG_CHANNEL_ID = "snappark_motion_channel"
        private const val FG_NOTIFICATION_ID = 1002

        // ── 주차 알림 (고우선, 헤즈업) ───────────────────────────────────
        private const val PARKING_CHANNEL_ID = "snappark_bt_channel"
        private const val PARKING_NOTIFICATION_ID = 1001

        // ── 모션 감지 파라미터 (체감 알림 5초 타겟) ──────────────────────
        //
        //  예상 타임라인 (일반 케이스):
        //    OS 브로드캐스트(~1.5s) + 서비스 시작(~0.4s) + RECONNECT_GUARD(1.5s)
        //    + BASELINE(0.2s) + 모션 감지(~0.5s) + 알림 렌더(~0.3s)  ≈ 4~5초
        //
        /**
         * 초기 대기 시간 (ms). BT 재연결 사이클(DISCONNECT→CONNECT)을 흡수한다.
         * 이 시간 내에 서비스가 stopSelf() 되면 오알림 없이 종료된다.
         *
         * ※ 3000ms → 1500ms 로 축소. 대부분의 차량 재연결 사이클은 1초 내 완료되므로
         *    1.5초면 충분히 흡수 가능하며, 전체 체감 지연이 약 1.5초 단축된다.
         */
        private const val RECONNECT_GUARD_MS = 1_500L

        /**
         * 기준 가속도 수집 기간 (ms). 차에 앉아있는 상태의 baseline 확보.
         * 300ms → 200ms 로 단축 (가속도계 ~50Hz 기준 약 10 샘플, baseline 평균 산출에 충분).
         */
        private const val BASELINE_DURATION_MS = 200L

        /**
         * 모션 감지 임계값 (m/s²).
         *
         * 중력(~9.8) 기준, 폰을 살짝 들거나 틸트하면 Δmag ≈ 0.5~1.5.
         * 주머니에 넣으며 걷기 시작하면 Δmag ≈ 2~5.
         * 1.0 → 0.7 로 하향: 벨트 클립 착용자나 컵홀더에서 폰을 집는 작은 움직임도
         * 즉시 포착되어 "하차 직후" 알림 도달 시간이 단축된다.
         */
        private const val MOTION_THRESHOLD = 0.7f

        /** 완전 정지 판정 시간 (ms). 이 시간 동안 모션 없으면 대기 모드. */
        @Suppress("unused")
        private const val STILL_TIMEOUT_MS = 10_000L

        /** 서비스 최대 수명 (ms). 어떤 상황에서든 이 시간 후 알림 발송. */
        private const val MAX_TIMEOUT_MS = 120_000L
    }

    private var sensorManager: SensorManager? = null
    private val baselineValues = mutableListOf<Float>()
    private var baselineMag: Float? = null
    private var startTime = 0L
    private var handler: Handler? = null
    private var triggered = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()

        ensureFgChannel()
        ensureParkingChannel()

        // ── 포그라운드 서비스 시작 ──────────────────────────────────────
        // Android 12+: 서비스 시작 후 5초 내에 startForeground 호출 필수.
        // shortService(Android 14+)는 서비스가 3초 내 종료되면 알림이 노출되지 않음.
        val fgNotification = buildForegroundNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                FG_NOTIFICATION_ID, fgNotification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE,
            )
        } else {
            startForeground(FG_NOTIFICATION_ID, fgNotification)
        }

        // ── 재연결 대기 후 가속도계 등록 ──────────────────────────────────
        // BT 연결 시 OS가 기존 ACL을 끊고 재연결하는 사이클(~1~2초)을 흡수한다.
        // 이 대기 중 ACL_CONNECTED → stopService() 가 호출되면 알림 없이 종료.
        handler = Handler(Looper.getMainLooper())
        handler?.postDelayed({
            if (triggered) return@postDelayed // 이미 취소됨

            sensorManager = getSystemService(SENSOR_SERVICE) as? SensorManager
            val accel = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

            if (accel != null) {
                sensorManager?.registerListener(this, accel, SensorManager.SENSOR_DELAY_GAME)
                startTime = SystemClock.elapsedRealtime()
                handler?.postDelayed(::onMaxTimeout, MAX_TIMEOUT_MS)
            } else {
                fireParkingNotification()
                stopSelf()
            }
        }, RECONNECT_GUARD_MS)

    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY // 시스템이 강제 종료 후 재시작 불필요

    // ── SensorEventListener ─────────────────────────────────────────────────

    override fun onSensorChanged(event: SensorEvent) {
        if (triggered) return

        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]
        val mag = sqrt(x * x + y * y + z * z)

        val elapsed = SystemClock.elapsedRealtime() - startTime

        // Phase 1: 베이스라인 수집 (첫 300ms)
        if (elapsed < BASELINE_DURATION_MS) {
            baselineValues.add(mag)
            return
        }

        // Phase 2: 베이스라인 확정 (1회)
        if (baselineMag == null && baselineValues.isNotEmpty()) {
            baselineMag = baselineValues.average().toFloat()
        }

        val baseline = baselineMag ?: return
        val delta = abs(mag - baseline)

        // Phase 3: 임계값 초과 → 즉시 알림
        if (delta > MOTION_THRESHOLD) {
            triggered = true
            fireParkingNotification()
            cleanup()
            stopSelf()
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    // ── 타임아웃 ────────────────────────────────────────────────────────────

    /** 2분 경과: 폰이 차에 남아있을 가능성 → 안전하게 알림 발송. */
    private fun onMaxTimeout() {
        if (triggered) return
        triggered = true
        fireParkingNotification()
        cleanup()
        stopSelf()
    }

    // ── 주차 알림 발송 ──────────────────────────────────────────────────────

    /**
     * 고우선 주차 알림을 발송한다.
     *
     * - PRIORITY_HIGH + IMPORTANCE_HIGH → 헤즈업 배너 + 소리 + 진동
     * - CATEGORY_REMINDER → 시스템 DND 필터에서 리마인더로 분류
     * - setFullScreenIntent → 잠금 화면에서도 즉시 노출
     * - onTap → MainActivity(PAYLOAD_OPEN_CAMERA) → Flutter 카메라 화면
     */
    private fun fireParkingNotification() {
        // 사용자가 서비스 실행 중에 자동 감지 토글을 OFF 로 바꾼 경우를 방어.
        // (Receiver 는 이벤트 진입 시점에만 한 번 검사하므로 여기서도 재확인)
        if (!SharedPrefsHelper.isBtAutoEnabled(this)) return

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(
                BluetoothDisconnectReceiver.EXTRA_PAYLOAD,
                BluetoothDisconnectReceiver.PAYLOAD_OPEN_CAMERA,
            )
        }
        val contentPi = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        // 잠금 화면 즉시 표시용 fullScreenIntent (동일 PendingIntent 재사용)
        val fullScreenPi = PendingIntent.getActivity(
            this, 2, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(this, PARKING_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_map)
            .setContentTitle("🚗 주차하셨나요?")
            .setContentText("📸 위치를 기록해두세요!")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .setContentIntent(contentPi)
            .setFullScreenIntent(fullScreenPi, true)
            .setVibrate(longArrayOf(0, 250, 100, 250))
            .setDefaults(NotificationCompat.DEFAULT_SOUND)
            .build()

        runCatching {
            NotificationManagerCompat.from(this).notify(PARKING_NOTIFICATION_ID, notification)
        }
    }

    // ── 포그라운드 서비스 알림 (임시) ────────────────────────────────────────

    private fun buildForegroundNotification(): Notification =
        NotificationCompat.Builder(this, FG_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_map)
            .setContentTitle("주차 감지 중")
            .setContentText("움직임을 감지하면 알림을 보내드립니다")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSilent(true)
            .setOngoing(true)
            .build()

    // ── 채널 생성 ───────────────────────────────────────────────────────────

    private fun ensureFgChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            FG_CHANNEL_ID, "주차 감지", NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "주차 후 움직임 감지 서비스 (임시)"
            setShowBadge(false)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun ensureParkingChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            PARKING_CHANNEL_ID, "주차 알림", NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "주차 위치 기록 알림 (고우선)"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 250, 100, 250)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    // ── 리소스 정리 ─────────────────────────────────────────────────────────

    private fun cleanup() {
        sensorManager?.unregisterListener(this)
        handler?.removeCallbacksAndMessages(null)
    }

    override fun onDestroy() {
        cleanup()
        super.onDestroy()
    }
}
