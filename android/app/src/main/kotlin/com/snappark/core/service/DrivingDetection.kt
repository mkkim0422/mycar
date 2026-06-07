package com.snappark.core.service

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.DetectedActivity
import com.snappark.core.receiver.DrivingStateReceiver

/**
 * 운전 감지(Activity Recognition - IN_VEHICLE) 구독 등록/해제 헬퍼.
 *
 * ## 왜 필요한가
 * "내 차 BT"를 이름·클래스로 추측하면 스피커·이어폰이 새어 들어온다.
 * 진짜 구분 신호는 **"그 기기가 운전 중에 연결돼 있었는가"** 다. 이 클래스는
 * OS 의 저전력 ActivityTransition API 로 IN_VEHICLE 진입/이탈을 받아
 * [DrivingStateReceiver] 로 전달한다.
 *
 * ## 배터리
 * - ActivityTransition 은 지속 GPS 가 아니라 가속도/스텝 등 센서 퓨전을 OS 가
 *   배치 처리하는 방식이라 상시 구동해도 영향이 작다.
 * - 우리는 IN_VEHICLE 의 ENTER/EXIT 두 전이만 구독한다.
 *
 * ## 권한
 * - API 29+: [Manifest.permission.ACTIVITY_RECOGNITION] 런타임 권한 필요.
 * - 미만: GMS 의 com.google.android.gms.permission.ACTIVITY_RECOGNITION (normal).
 * - 권한이 없으면 [register]는 조용히 no-op 한다 → 학습이 시작되지 않을 뿐 크래시 없음.
 */
object DrivingDetection {

    private const val REQUEST_CODE = 4201

    /** ACTIVITY_RECOGNITION 런타임 권한 보유 여부 (API 29+ 한정 검사). */
    fun hasPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACTIVITY_RECOGNITION,
        ) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * IN_VEHICLE 전이 업데이트를 구독한다. 권한이 없으면 no-op.
     * 동일 PendingIntent 로 재호출해도 안전(중복 구독이 교체된다)하므로
     * MainActivity onResume / BootReceiver 등에서 반복 호출해도 무방하다.
     */
    fun register(context: Context) {
        if (!hasPermission(context)) {
            Log.d("SnapPark", "운전 감지 등록 skip: ACTIVITY_RECOGNITION 권한 없음")
            return
        }

        val transitions = listOf(
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                .build(),
        )
        val request = ActivityTransitionRequest(transitions)

        runCatching {
            ActivityRecognition.getClient(context)
                .requestActivityTransitionUpdates(request, buildPendingIntent(context))
                .addOnSuccessListener { Log.d("SnapPark", "운전 감지 등록 성공") }
                .addOnFailureListener { e -> Log.w("SnapPark", "운전 감지 등록 실패: $e") }
        }
    }

    /** 구독 해제 (현재 UI 흐름에선 사용하지 않지만 대칭성/디버그용으로 제공). */
    fun unregister(context: Context) {
        if (!hasPermission(context)) return
        runCatching {
            ActivityRecognition.getClient(context)
                .removeActivityTransitionUpdates(buildPendingIntent(context))
        }
    }

    private fun buildPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, DrivingStateReceiver::class.java)
        // FLAG_MUTABLE 필수: 시스템이 결과 extras 를 PendingIntent 에 채워 넣는다.
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }
}
