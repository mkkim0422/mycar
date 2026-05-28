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
import com.snappark.core.data.SecurePrefsHelper
import com.snappark.core.data.SharedPrefsHelper
import com.snappark.core.service.MotionDetectionService

/**
 * 블루투스 연결 해제 이벤트를 수동으로 수신하는 BroadcastReceiver.
 *
 * ## 동작 흐름 (v2 — 모션 감지 통합)
 * 1. OS 가 [ACL_DISCONNECTED] 브로드캐스트 → [onReceive] 호출
 * 2. [MotionDetectionService] 포그라운드 서비스 시작
 *    → 가속도계로 "하차 모션" 감지 → 즉시 주차 알림 (< 3초 지연)
 * 3. 서비스 시작 실패 시 → 즉시 알림 발송 (레거시 폴백)
 *
 * ## 설계 원칙 (배터리 최적화)
 * - 지속적인 BT 스캔(BluetoothLeScanner 등)을 사용하지 않는다.
 * - OS가 [android.bluetooth.device.action.ACL_DISCONNECTED] 브로드캐스트를
 *   보낼 때만 [onReceive]가 호출된다 → 완전 수동(Passive) 구조.
 * - [MotionDetectionService] 수명 ≤ 2분, 대부분 1~3초 내 종료.
 *
 * ## 자동 등록 방식
 * - AndroidManifest.xml의 <receiver> 태그로 선언적 등록 → 앱이 꺼진 상태에서도
 *   OS가 직접 이 클래스를 인스턴스화하여 호출한다.
 *
 * ## Android 12+ 포그라운드 서비스 제한 예외
 * - Bluetooth 브로드캐스트 수신자에서의 포그라운드 서비스 시작은
 *   Android 12+(API 31) 백그라운드 제한에서 **면제**된다.
 */
class BluetoothDisconnectReceiver : BroadcastReceiver() {

    companion object {
        private const val CHANNEL_ID = "snappark_bt_channel"
        private const val CHANNEL_NAME = "주차 위치 알림"
        private const val NOTIFICATION_ID = 1001

        // Flutter → Android 앱 런치 시 전달할 extra 키
        // NotificationService.dart의 payload 값과 동일하게 맞춘다.
        const val EXTRA_PAYLOAD = "snappark_payload"
        const val PAYLOAD_OPEN_CAMERA = "open_camera"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)

        when (intent.action) {
            // ── BT 재연결 → 실행 중인 모션 감지 서비스 즉시 취소 ─────────
            // 차량 BT 연결 시 OS가 기존 ACL을 끊고(DISCONNECTED) 재연결(CONNECTED)
            // 하는 과정에서 오알림이 발생할 수 있다. 재연결 시 서비스를 중단한다.
            BluetoothDevice.ACTION_ACL_CONNECTED -> {
                Log.d("SnapPark", "BT connected: ${device?.name} → 서비스 취소")
                runCatching { context.stopService(Intent(context, MotionDetectionService::class.java)) }

                // ── 차량 디바이스 재연결 → 알림 라치 해제 (새 주차 사이클 시작) ──
                //    "끊김 사이클당 알림 1회" 보장의 핵심: 라치는 시간이 아니라
                //    **차량 ACL_CONNECTED** 로만 풀린다. 비차량(이어폰·워치 등) 이
                //    풀면 그 직후 같은 기기의 끊김이 가설 A(자동 필터 오인식)로
                //    알림을 발사할 수 있다. stopService 는 BT flicker 흡수용으로
                //    유지하되, 라치 해제는 isCarDevice 통과 시에만 수행.
                if (device != null && isCarDevice(context, device)) {
                    SharedPrefsHelper.clearParkingNotificationLatch(context)
                    Log.d("SnapPark", "차량 재연결 → 알림 라치 해제")
                }
                return
            }

            BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                // ── 사용자 설정: 자동 감지 OFF 면 어떤 알림도 발송하지 않음 ─────
                // ※ 이 검사를 CONNECTED 분기 아래에 둔 이유: 사용자가 OFF 상태에서
                //   실수로 이미 시작된 서비스가 남아있다면 DISCONNECTED 전에 도착하는
                //   CONNECTED 이벤트로도 정리되어야 하므로, CONNECTED 는 항상 통과.
                if (!SharedPrefsHelper.isBtAutoEnabled(context)) {
                    Log.d("SnapPark", "BT 자동 감지 OFF → 알림 발송 차단")
                    // 혹시 실행 중인 모션 감지 서비스도 즉시 중단한다.
                    runCatching { context.stopService(Intent(context, MotionDetectionService::class.java)) }
                    return
                }

                // 차량 기기만 자동 필터링 (이어폰, 워치 등 무시)
                if (device != null && !isCarDevice(context, device)) {
                    Log.d("SnapPark", "BT disconnect 무시: ${device.name} (차량 기기 아님)")
                    return
                }
                Log.d("SnapPark", "BT disconnect 감지: ${device?.name} → 모션 감지 시작")
            }

            else -> return
        }

        // ── 모션 감지 서비스 시작 (< 3초 지연 목표) ──────────────────────
        val serviceIntent = Intent(context, MotionDetectionService::class.java)
        val started = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        }.isSuccess

        // 서비스 시작 실패 → 레거시 폴백: 즉시 알림 발송
        if (!started) {
            showNotificationDirectly(context)
        }
    }

    // ── 레거시 폴백: 서비스 없이 즉시 알림 ──────────────────────────────────

    private fun showNotificationDirectly(context: Context) {
        // 모든 알림 경로가 거치는 단일 dedupe 가드. 서비스 측 fireParkingNotification 과
        // 동일한 키·쿨다운을 공유하므로, 폴백이 발사된 직후 서비스가 정상 시작되어
        // 또 한 번 발사 시도해도 차단된다 (그 반대도 성립).
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
        val pendingIntent = PendingIntent.getActivity(
            context, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_map)
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
        // notify 예외 여부와 무관하게 시도 자체를 기록 — 짧은 재시도 폭주를 막는다.
        SharedPrefsHelper.markParkingNotificationFired(context)
    }

    /**
     * 연결 해제된 기기가 **차량 블루투스**인지 포괄적으로 판별한다.
     *
     * ## 설계 원칙 (수동 태깅 = exclusive 모드, 미태깅 = 자동 필터)
     * 0. **수동 태깅 모드 (exclusive)** — 사용자가 '내 차' 로 태깅한 기기가 있으면
     *    *그 기기의 MAC 과 일치할 때만* true, 그 외는 모두 false.
     *    설정 화면 안내 문구가 약속하는 동작: "해당 기기의 연결 해제만 감지".
     *    ※ 태깅은 OS 이벤트 필터링 힌트일 뿐, 새로운 BT 연결/스캔은 시도하지 않는다.
     *    ※ MAC 은 AndroidKeyStore 로 보호되는 SecurePrefsHelper 에서 복호화 조회.
     * 1. **(태깅 없을 때만) 이어폰 차단 우선** — 이름·클래스 블록리스트로 개인
     *    오디오 기기 제외
     * 2. **(태깅 없을 때만) 차량 신호 포괄 수용** — 블록리스트를 통과한 기기는
     *    다음 신호 중 하나면 차량
     *    - CAR_AUDIO 클래스 (확정)
     *    - HANDSFREE 클래스 (이어폰은 이미 위 단계에서 제거됨 → 핸즈프리 카 킷으로 간주)
     *    - 국산/해외 차량 브랜드·인포테인먼트 시스템 이름 키워드
     *    - AUDIO_VIDEO Major + Classic BT 타입 (현대 이어폰은 대부분 DUAL 이라 제외됨)
     * 3. **2단 방어** — BT 해제 후에도 [MotionDetectionService] 가 하차 모션이 없으면
     *    알림을 발송하지 않으므로, 차량 감지를 넉넉히 잡아도 오알림 위험이 낮다.
     */
    @Suppress("DEPRECATION")
    private fun isCarDevice(context: Context, device: BluetoothDevice): Boolean {
        // ── 0) 수동 태깅 모드 (exclusive) ──────────────────────────────
        //    태깅된 MAC 이 존재하면 그 기기와의 정확 일치 여부만 판단한다.
        //    설정 UI 의 안내 문구("해당 기기의 연결 해제만 감지") 와 일치시키기 위해
        //    *불일치 시 자동 필터로 폴백하지 않는다*. 즉 태깅 후에는 다른 차량
        //    기기(렌터카, 지인 차 등) 가 해제돼도 알림이 발송되지 않는다.
        val manualCarId = SecurePrefsHelper.getManualCarId(context)
        if (manualCarId != null) {
            val deviceAddr = runCatching { device.address?.uppercase() }.getOrNull()
            val matches = deviceAddr != null && deviceAddr == manualCarId
            Log.d(
                "SnapPark",
                "수동 태깅 모드: 일치=$matches (event=${device.address}, tagged=$manualCarId)",
            )
            return matches
        }

        val btClass = runCatching { device.bluetoothClass }.getOrNull()
        val deviceClass = btClass?.deviceClass ?: 0
        val majorClass = btClass?.majorDeviceClass ?: -1
        val name = runCatching { device.name?.lowercase() }.getOrNull().orEmpty()

        // ── 1) 이어폰/헤드폰 이름 키워드 → 즉시 제외 ─────────────────────
        //    HANDSFREE 클래스를 쓰는 이어폰도 여기서 대부분 걸러진다.
        val earKeywords = listOf(
            "buds", "airpod", "earphone", "earpod", "headphone", "headset",
            "earbud", "pods", "freebuds", "wf-", "wh-", "beats", "jbl",
            "bose qc", "bose quiet", "bose sport", "soundcore", "liberty",
            "momentum", "galaxy buds", "sony wh", "sony wf",
            "이어폰", "이어버드", "헤드폰", "헤드셋",
        )
        if (earKeywords.any { name.contains(it) }) return false

        // ── 2) 개인 오디오 기기 클래스 → 즉시 제외 ───────────────────────
        if (deviceClass == BluetoothClass.Device.AUDIO_VIDEO_HEADPHONES ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_WEARABLE_HEADSET ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_LOUDSPEAKER ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_PORTABLE_AUDIO ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_HIFI_AUDIO ||
            deviceClass == BluetoothClass.Device.AUDIO_VIDEO_MICROPHONE) {
            return false
        }

        // ── 3) 차량이 아닌 Major 클래스 → 즉시 제외 ──────────────────────
        if (majorClass == BluetoothClass.Device.Major.PHONE ||
            majorClass == BluetoothClass.Device.Major.COMPUTER ||
            majorClass == BluetoothClass.Device.Major.PERIPHERAL ||
            majorClass == BluetoothClass.Device.Major.WEARABLE ||
            majorClass == BluetoothClass.Device.Major.IMAGING ||
            majorClass == BluetoothClass.Device.Major.TOY ||
            majorClass == BluetoothClass.Device.Major.HEALTH) {
            return false
        }

        // ── 4) CAR_AUDIO 클래스 → 차량 확정 ──────────────────────────────
        if (deviceClass == BluetoothClass.Device.AUDIO_VIDEO_CAR_AUDIO) return true

        // ── 5) HANDSFREE 클래스 → 차량 핸즈프리 킷으로 간주 ───────────────
        //    이어폰은 위 1~3 단계에서 이미 제거되었다.
        if (deviceClass == BluetoothClass.Device.AUDIO_VIDEO_HANDSFREE) return true

        // ── 6) 국산/해외 차량 브랜드·시스템 키워드 → 차량 확정 ────────────
        val carKeywords = listOf(
            // 일반 용어
            "car", "auto", "vehicle", "obd", "car audio", "car kit",
            "carplay", "android auto", "mirrorlink", "infotainment",
            "차량", "자동차", "차량용",

            // ── 국산 브랜드 / 인포테인먼트 ─────────────────────────────
            "현대", "기아", "제네시스", "쉐보레", "쌍용", "르노", "삼성자동차",
            "hyundai", "kia", "genesis", "chevrolet", "chevy",
            "ssangyong", "kgm", "kg mobility", "renault",
            "bluelink", "uvo", "kia connect",

            // ── 독일 ─────────────────────────────────────────────────
            "bmw", "idrive", "mini cooper",
            "mercedes", "benz", "maybach", "amg", "mbux",
            "audi", "mmi",
            "volkswagen", "porsche", "pcm",
            "skoda", "cupra", "seat leon",

            // ── 일본 ─────────────────────────────────────────────────
            "toyota", "lexus", "acura", "honda",
            "nissan", "infiniti", "mazda", "mitsubishi", "subaru",

            // ── 미국 ─────────────────────────────────────────────────
            "ford", "lincoln", "sync",
            "tesla", "cybertruck",
            "jeep", "chrysler", "dodge", "uconnect", "ram 1500",
            "cadillac", "buick", "onstar", "gmc",
            "rivian", "lucid air", "fisker",

            // ── 이탈리아 / 영국 / 슈퍼카 ───────────────────────────────
            "fiat", "alfa romeo", "maserati", "ferrari",
            "lamborghini", "bugatti",
            "bentley", "rolls royce", "rolls-royce",
            "aston martin", "mclaren", "lotus",
            "jaguar", "land rover", "range rover",

            // ── 북유럽 ────────────────────────────────────────────────
            "volvo", "polestar", "sensus",

            // ── 프랑스 / 벨기에 ───────────────────────────────────────
            "peugeot", "citroen", "opel", "vauxhall", "ds automobiles",

            // ── 중국 ─────────────────────────────────────────────────
            "byd", "nio", "xpeng", "geely", "chery", "great wall",
            "mg motor",
        )
        if (carKeywords.any { name.contains(it) }) return true

        // ── 7) AUDIO_VIDEO Major + Classic BT 타입 → 전통 카 오디오 ──────
        //    이어폰/버즈는 대부분 DUAL(BLE+Classic) 모드이므로 걸리지 않는다.
        if (majorClass == BluetoothClass.Device.Major.AUDIO_VIDEO) {
            val type = runCatching { device.type }
                .getOrDefault(BluetoothDevice.DEVICE_TYPE_UNKNOWN)
            if (type == BluetoothDevice.DEVICE_TYPE_CLASSIC) return true
        }

        // ── 8) 불확실 → 알림 보내지 않음 ─────────────────────────────────
        return false
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
