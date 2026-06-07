package com.snappark.core.receiver

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.snappark.MainActivity
import com.snappark.R
import com.snappark.core.data.SecurePrefsHelper
import com.snappark.core.data.SharedPrefsHelper
import com.snappark.core.service.MotionDetectionService

/**
 * 블루투스 연결/해제 이벤트를 수신해 **"내 차 BT"가 끊겼을 때만** 주차 알림 흐름을
 * 시작하는 BroadcastReceiver.
 *
 * ## 핵심 설계 — "추측"이 아니라 "학습"
 * 과거 버전은 기기 이름·클래스로 차량을 *추측*했다. 그 결과 BT 스피커("lightspeaker7"),
 * 회의용 스피커폰, TV 등 비차량 오디오가 차로 오인식돼 오알림이 발생했다.
 * 특히 ACL_DISCONNECTED 시점에는 `device.name` 이 null 인 경우가 많아 이름 기반
 * 판별 자체가 불안정했다.
 *
 * v3 는 차량을 **자동 학습**한다:
 *  1. **연결(CONNECTED)** 시점(이름이 살아있는 시점)에 "차량 후보"(오디오 기기이고
 *     이어폰·스피커가 아님)만 추려 [SecurePrefsHelper] 연결 집합에 넣는다.
 *  2. **운전 감지([DrivingStateReceiver], IN_VEHICLE)** 가 그 후보를 "이번 운전과
 *     함께한 기기"로 표시한다.
 *  3. **해제(DISCONNECTED)** 시 그 기기가 운전과 함께했으면 득표. 서로 다른 운전
 *     [SecurePrefsHelper.DISTINCT_TRIPS_TO_LEARN] 회를 채우면 "내 차"로 확정.
 *  4. 확정 이후에는 **그 MAC 의 해제만** 알림 흐름을 탄다. 끊김 시점엔 이름이 아니라
 *     **MAC** 으로만 매칭하므로 null name 문제가 사라진다.
 *
 * 집 스피커는 운전과 무관해 표가 안 쌓이고, 이어폰은 후보 단계에서 탈락한다.
 *
 * ## 우선순위
 *  - 사용자가 직접 태깅한 [SecurePrefsHelper.getManualCarId] 가 있으면 그것이 최우선
 *    (학습보다 우선). 없으면 학습된 [SecurePrefsHelper.getLearnedCarId] 사용.
 *  - 둘 다 없으면 "학습 모드" — 자동 알림을 발사하지 않고 조용히 학습만 한다.
 *
 * ## 설계 원칙 (배터리)
 *  - 지속 BT 스캔 없음. OS 의 ACL 브로드캐스트에만 수동 반응.
 *  - 운전 감지는 저전력 ActivityTransition API.
 */
class BluetoothDisconnectReceiver : BroadcastReceiver() {

    companion object {
        private const val CHANNEL_ID = "snappark_bt_channel"
        private const val CHANNEL_NAME = "주차 위치 알림"
        private const val NOTIFICATION_ID = 1001

        // Flutter → Android 앱 런치 시 전달할 extra 키
        const val EXTRA_PAYLOAD = "snappark_payload"
        const val PAYLOAD_OPEN_CAMERA = "open_camera"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
        val mac = runCatching { device?.address?.uppercase() }.getOrNull()

        when (intent.action) {
            // ── BT 연결 ────────────────────────────────────────────────────
            BluetoothDevice.ACTION_ACL_CONNECTED -> {
                // 차량 재연결 사이클(DISCONNECT→CONNECT)의 오알림 흡수: 진행 중인
                // 모션 감지 서비스가 있으면 중단.
                runCatching { context.stopService(Intent(context, MotionDetectionService::class.java)) }

                if (mac == null) return
                val targetMac = resolveTargetCarMac(context)

                if (targetMac != null) {
                    // 내 차(수동/학습)가 다시 연결됨 = 새 주차 사이클 → 알림 라치 해제.
                    if (mac == targetMac) {
                        SharedPrefsHelper.clearParkingNotificationLatch(context)
                        Log.d("SnapPark", "내 차 재연결 → 알림 라치 해제")
                    }
                } else {
                    // 학습 모드: 차량 후보면 연결 집합에 등록(이름이 살아있는 지금 판정).
                    if (device != null && isLearningCandidate(device)) {
                        SecurePrefsHelper.addConnectedCandidate(context, mac)
                        Log.d("SnapPark", "차량 후보 연결: ${device.name} ($mac)")
                    }
                }
                return
            }

            // ── BT 해제 ────────────────────────────────────────────────────
            BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                // 연결 집합 정리는 항상 먼저 수행한다(타깃 모드에선 no-op). 자동 감지 OFF
                // 분기보다 앞에 둔 이유: OFF 동안 해제된 기기를 connected set 에서 못 빼면
                // 스테일 항목으로 남아, 다시 ON 했을 때 묵은 항목이 trip 에 끼어 부당 득표할
                // 수 있다(리뷰 발견). 정리는 알림과 무관한 안전한 동작이라 OFF 여도 수행.
                if (mac != null) SecurePrefsHelper.removeConnectedCandidate(context, mac)

                if (!SharedPrefsHelper.isBtAutoEnabled(context)) {
                    Log.d("SnapPark", "BT 자동 감지 OFF → 차단")
                    runCatching {
                        context.stopService(Intent(context, MotionDetectionService::class.java))
                    }
                    return
                }

                if (mac == null) {
                    // MAC 을 알 수 없으면 "내 차"인지 확인할 길이 없다 → 오알림 방지 위해 무시.
                    Log.d("SnapPark", "해제 무시: MAC 불명")
                    return
                }

                val targetMac = resolveTargetCarMac(context)
                if (targetMac != null) {
                    // ── 확정 단계: 내 차의 MAC 일 때만 발사 ──────────────────
                    if (mac == targetMac) {
                        Log.d("SnapPark", "내 차 해제 감지 → 모션 감지 시작")
                        startMotionService(context)
                    } else {
                        Log.d("SnapPark", "해제 무시: 내 차 아님 ($mac)")
                    }
                    return
                }

                // ── 학습 단계: 운전과 함께한 기기면 득표. 막 확정됐다면 발사 ──
                val justLearned = SecurePrefsHelper.registerTripAndMaybeLearn(
                    context, mac, runCatching { device?.name }.getOrNull(),
                )
                if (justLearned) {
                    Log.i("SnapPark", "차량 자동 학습 완료 ($mac) → 첫 알림 발사")
                    startMotionService(context)
                } else {
                    Log.d("SnapPark", "학습 진행 중 또는 비운전 해제 → 발사 안 함 ($mac)")
                }
                return
            }

            else -> return
        }
    }

    // ── 타깃 차량 MAC 결정 (수동 태깅 > 자동 학습) ───────────────────────────
    private fun resolveTargetCarMac(context: Context): String? =
        SecurePrefsHelper.getManualCarId(context) ?: SecurePrefsHelper.getLearnedCarId(context)

    // ── 모션 감지 서비스 시작 (실패 시 즉시 알림 폴백) ───────────────────────
    private fun startMotionService(context: Context) {
        val serviceIntent = Intent(context, MotionDetectionService::class.java)
        val started = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }.isSuccess
        if (!started) showNotificationDirectly(context)
    }

    /**
     * 끊긴 기기가 **차량 후보**인지 판별한다 (학습 후보 자격).
     *
     * 여기서는 "차량 확정"이 아니라 "학습 대상으로 지켜볼 가치가 있는가"만 본다.
     * 실제 차량 여부는 이후 운전 감지(IN_VEHICLE) 가 검증하므로, 후보 기준은
     * "오디오 기기이면서 이어폰/스피커가 아님" 정도로 충분하다.
     *
     * - 이어폰/헤드셋/스피커류는 이름·클래스로 제외 (특히 BT 스피커 오알림 차단).
     * - 폰/PC/워치/주변기기 등 비오디오 Major 는 애초에 후보가 아니다.
     */
    @Suppress("DEPRECATION")
    private fun isLearningCandidate(device: BluetoothDevice): Boolean {
        val name = runCatching { device.name?.lowercase() }.getOrNull().orEmpty()

        // 1) 이어폰·스피커 등 개인 오디오 이름 키워드 → 후보 제외
        val excludeKeywords = listOf(
            // 이어폰·헤드셋
            "buds", "airpod", "earphone", "earpod", "headphone", "headset",
            "earbud", "pods", "freebuds", "wf-", "wh-", "beats", "galaxy buds",
            "sony wh", "sony wf", "이어폰", "이어버드", "헤드폰", "헤드셋",
            // 스피커 (BT 스피커 오알림의 직접 원인 — lightspeaker7 등)
            "speaker", "스피커", "soundbar", "사운드바", "soundlink", "soundcore",
            "boom", "flip", "charge", "pulse", "clip", "wonderboom", "megaboom",
            "jbl", "bose", "marshall", "마샬", "sound link",
        )
        if (excludeKeywords.any { name.contains(it) }) return false

        val btClass = runCatching { device.bluetoothClass }.getOrNull()
        val deviceClass = btClass?.deviceClass ?: 0
        val majorClass = btClass?.majorDeviceClass ?: -1

        // 2) 개인 오디오/스피커 클래스 → 후보 제외
        if (deviceClass == BluetoothClass.Device.AUDIO_VIDEO_HEADPHONES ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_WEARABLE_HEADSET ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_LOUDSPEAKER ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_PORTABLE_AUDIO ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_HIFI_AUDIO ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_MICROPHONE) {
            return false
        }

        // 3) CAR_AUDIO / HANDSFREE 클래스 → 명백한 차량 오디오 후보
        if (deviceClass == BluetoothClass.Device.AUDIO_VIDEO_CAR_AUDIO ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_HANDSFREE) {
            return true
        }

        // 4) 그 외 AUDIO_VIDEO Major 의 오디오 기기 → 후보로 지켜본다(운전이 검증).
        return majorClass == BluetoothClass.Device.Major.AUDIO_VIDEO
    }

    // ── 레거시 폴백: 서비스 시작 실패 시 즉시 알림 ───────────────────────────
    private fun showNotificationDirectly(context: Context) {
        if (!SharedPrefsHelper.shouldFireParkingNotification(context)) {
            Log.i("SnapPark", "parking notification suppressed (cooldown, reason=receiver_fallback)")
            return
        }
        Log.i("SnapPark", "parking notification firing (reason=receiver_fallback)")

        createNotificationChannelIfNeeded(context)

        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_PAYLOAD, PAYLOAD_OPEN_CAMERA)
        }
        // 요청코드 10: MotionDetectionService 의 content(0)/fullScreen(2) PendingIntent 와
        // 구분한다. 같은 코드+동일 타깃이면 FLAG_UPDATE_CURRENT 로 extras 가 교차 오염될
        // 수 있어(현재는 payload 동일해 무해하나) 코드를 분리해 둔다.
        val pendingIntent = PendingIntent.getActivity(
            context, 10, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("🚗 주차하셨나요?")
            .setContentText("📸 위치를 기록해두세요!")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setVibrate(longArrayOf(0, 250, 100, 250))
            .setBadgeIconType(NotificationCompat.BADGE_ICON_NONE)
            .setNumber(0)
            .build()

        runCatching {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        }
        SharedPrefsHelper.markParkingNotificationFired(context)
    }

    private fun createNotificationChannelIfNeeded(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "블루투스 연결 해제 시 주차 위치 기록을 유도하는 알림"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 250, 100, 250)
            setShowBadge(false)
        }

        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }
}
