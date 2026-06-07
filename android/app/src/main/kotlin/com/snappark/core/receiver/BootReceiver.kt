package com.snappark.core.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.snappark.core.service.DrivingDetection

/**
 * 재부팅 후 운전 감지(Activity Recognition) 구독을 복원하는 수신기.
 *
 * ActivityTransition 구독은 기기 재부팅 시 사라지므로, BOOT_COMPLETED 에서
 * [DrivingDetection.register]를 다시 호출해 차량 자동 학습이 끊기지 않게 한다.
 * 권한이 없으면 register 가 내부적으로 no-op 한다.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        Log.d("SnapPark", "부팅 완료 → 운전 감지 재등록")
        DrivingDetection.register(context.applicationContext)
    }
}
