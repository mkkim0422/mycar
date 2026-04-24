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
            .build()

        runCatching {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        }
    }

    /**
     * 연결 해제된 기기가 **차량 블루투스**인지 포괄적으로 판별한다.
     *
     * ## 설계 원칙 (수동 태깅 최우선 → 자동 필터)
     * 0. **수동 태깅 바이패스** — 사용자가 설정에서 '내 차'로 태깅한 MAC 과 일치하면
     *    자동 필터(1~7)를 전부 건너뛰고 즉시 true.
     *    ※ 태깅은 OS 이벤트 필터링 힌트일 뿐이며, 새로운 BT 연결/스캔을 시도하지 않는다.
     * 1. **이어폰 차단 우선** — 이름·클래스 블록리스트로 개인 오디오 기기 제외
     * 2. **차량 신호 포괄 수용** — 블록리스트를 통과한 기기는 다음 신호 중 하나면 차량
     *    - CAR_AUDIO 클래스 (확정)
     *    - HANDSFREE 클래스 (이어폰은 이미 위 단계에서 제거됨 → 핸즈프리 카 킷으로 간주)
     *    - 국산/해외 차량 브랜드·인포테인먼트 시스템 이름 키워드
     *    - AUDIO_VIDEO Major + Classic BT 타입 (현대 이어폰은 대부분 DUAL 이라 제외됨)
     * 3. **2단 방어** — BT 해제 후에도 [MotionDetectionService] 가 하차 모션이 없으면
     *    알림을 발송하지 않으므로, 차량 감지를 넉넉히 잡아도 오알림 위험이 낮다.
     */
    @Suppress("DEPRECATION")
    private fun isCarDevice(context: Context, device: BluetoothDevice): Boolean {
        // ── 0) 수동 태깅 바이패스 (최우선) ──────────────────────────────
        //    사용자가 설정 > '알림이 오지 않나요?' 에서 선택한 기기의 MAC 과 일치하면
        //    자동 판별 로직을 건너뛰고 즉시 차량으로 간주한다.
        //    ※ BT 연결 시도/스캔 없음 — OS 가 쏜 이벤트의 기기 주소를 비교만 한다.
        //    ※ MAC 은 AndroidKeyStore 로 보호되는 SecurePrefsHelper 에서 복호화 조회.
        val manualCarId = SecurePrefsHelper.getManualCarId(context)
        if (manualCarId != null) {
            val deviceAddr = runCatching { device.address?.uppercase() }.getOrNull()
            if (deviceAddr != null && deviceAddr == manualCarId) {
                Log.d("SnapPark", "수동 태깅 기기 일치 → 자동 필터 바이패스")
                return true
            }
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
        }

        (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }
}
