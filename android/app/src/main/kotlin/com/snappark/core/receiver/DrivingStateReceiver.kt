package com.snappark.core.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.snappark.core.data.SecurePrefsHelper
import com.snappark.core.data.SharedPrefsHelper

/**
 * 운전 감지(IN_VEHICLE) 전이 이벤트 수신기.
 *
 * [DrivingDetection]이 등록한 PendingIntent 로 OS 가 ActivityTransitionResult 를
 * 전달하면, IN_VEHICLE 의 ENTER/EXIT 를 [SecurePrefsHelper] 운전 상태에 반영한다.
 *
 * ## 차량 자동 학습에서의 역할
 * - ENTER → [SecurePrefsHelper.onDrivingStarted] : 지금 연결된 BT 후보들을
 *   "이번 운전과 함께한 기기"로 표시 → 나중에 끊길 때 차량 득표로 이어진다.
 * - EXIT  → [SecurePrefsHelper.onDrivingStopped] : 운전 종료 플래그만 내린다
 *   (driven cycle 은 끊김에서 소비할 때까지 보존).
 *
 * exported=false: 우리 PendingIntent 로만 호출된다.
 */
class DrivingStateReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return

        for (event in result.transitionEvents) {
            if (event.activityType != DetectedActivity.IN_VEHICLE) continue
            when (event.transitionType) {
                ActivityTransition.ACTIVITY_TRANSITION_ENTER -> {
                    Log.d("SnapPark", "운전 시작 감지 (IN_VEHICLE ENTER)")
                    SecurePrefsHelper.onDrivingStarted(context)
                    // 새 주행 시작 = 새 주차 사이클 → 알림 라치 해제.
                    // 라치는 원래 차량 ACL_CONNECTED 로만 풀리는데, 그 브로드캐스트가
                    // 누락되면 직전 라치가 최대 6시간 알림을 막는다(리뷰 Item). 운전 재개를
                    // 추가 해제 트리거로 두어 그 사이 주차 알림이 막히지 않게 한다.
                    SharedPrefsHelper.clearParkingNotificationLatch(context)
                }
                ActivityTransition.ACTIVITY_TRANSITION_EXIT -> {
                    Log.d("SnapPark", "운전 종료 감지 (IN_VEHICLE EXIT)")
                    SecurePrefsHelper.onDrivingStopped(context)
                }
            }
        }
    }
}
