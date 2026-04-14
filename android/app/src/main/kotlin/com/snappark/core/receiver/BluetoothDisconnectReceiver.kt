package com.snappark.core.receiver

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.snappark.MainActivity

/**
 * 블루투스 연결 해제 이벤트를 수동으로 수신하는 BroadcastReceiver.
 *
 * ## 설계 원칙 (배터리 최적화)
 * - 지속적인 BT 스캔(BluetoothLeScanner 등)을 사용하지 않는다.
 * - OS가 [android.bluetooth.device.action.ACL_DISCONNECTED] 브로드캐스트를
 *   보낼 때만 [onReceive]가 호출된다 → 완전 수동(Passive) 구조.
 * - [onReceive] 실행 시간은 매우 짧으며(알림 빌드 후 즉시 종료), WakeLock 불필요.
 *
 * ## 자동 등록 방식
 * - AndroidManifest.xml의 <receiver> 태그로 선언적 등록 → 앱이 꺼진 상태에서도
 *   OS가 직접 이 클래스를 인스턴스화하여 호출한다.
 *
 * ## Flutter 연동 고려사항
 * - 알림을 탭하면 [MainActivity]로 복귀하며, Flutter 앱이 실행 중이면
 *   [NotificationService] (Dart)의 onDidReceiveNotificationResponse 콜백이
 *   호출되어 카메라 화면으로 라우팅된다.
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
        // ACL_DISCONNECTED 인텐트 필터만 선언했지만, 방어적으로 재확인
        if (intent.action != BluetoothDevice.ACTION_ACL_DISCONNECTED) return

        // Android 8.0(O)+ 에서는 채널이 없으면 알림이 표시되지 않음
        createNotificationChannelIfNeeded(context)

        // 알림 탭 시 MainActivity를 포그라운드로 가져오는 PendingIntent
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_PAYLOAD, PAYLOAD_OPEN_CAMERA)
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            // Android 12+: FLAG_IMMUTABLE 필수
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_map)
            .setContentTitle("주차하셨나요?")
            .setContentText("위치를 기록해두세요! 탭하면 카메라가 열립니다.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            // Heads-up 알림 표시 (화면이 켜진 상태에서도 즉시 노출)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        // POST_NOTIFICATIONS 권한은 Flutter NotificationService에서
        // 런타임 요청 후 부여된다. 권한이 없으면 SecurityException 대신
        // 조용히 무시 (notify가 내부적으로 처리).
        runCatching {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Android 8.0+(API 26+)에서 알림 채널을 생성한다.
     * 이미 존재하면 OS가 무시하므로 중복 호출해도 안전하다.
     */
    private fun createNotificationChannelIfNeeded(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            // HIGH: 소리 + 헤즈업 배너 표시
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "블루투스 연결 해제 시 주차 위치 기록을 유도하는 알림"
        }

        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.createNotificationChannel(channel)
    }
}
