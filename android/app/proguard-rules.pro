# ══════════════════════════════════════════════════════════════════════════
# SnapPark V2 ProGuard / R8 Rules — 상용 배포용 난독화 설정
# ══════════════════════════════════════════════════════════════════════════

# ── Flutter ──────────────────────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ── Kotlin ───────────────────────────────────────────────────────────────
-keep class kotlin.Metadata { *; }
-keepclassmembers class kotlin.Metadata { *; }
-dontwarn kotlin.**
-dontwarn kotlinx.**

# ── Google ML Kit (OCR) ──────────────────────────────────────────────────
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_** { *; }
-dontwarn com.google.mlkit.**

# ── Google Mobile Ads (AdMob 배너) ───────────────────────────────────────
-keep class com.google.android.gms.ads.** { *; }
-dontwarn com.google.android.gms.ads.**

# ── Google Play Billing (in_app_purchase: 광고 제거 결제) ─────────────────
-keep class com.android.billingclient.** { *; }
-dontwarn com.android.billingclient.**

# ── Kakao SDK ────────────────────────────────────────────────────────────
-keep class com.kakao.sdk.** { *; }
-keep class com.kakao.flutter.sdk.** { *; }
-dontwarn com.kakao.**

# ── AndroidX ─────────────────────────────────────────────────────────────
-keep class androidx.core.app.NotificationCompat** { *; }
-keep class androidx.exifinterface.media.ExifInterface { *; }
-keep class androidx.lifecycle.** { *; }
-dontwarn androidx.**

# ── AndroidX Security (EncryptedSharedPreferences / MasterKey) ───────────
# 리플렉션으로 BouncyCastle/Tink 프로바이더에 접근하므로 전체 보존 필수.
# R8 이 내부 클래스를 제거하면 "Cannot find KeyStore provider" 런타임 크래시.
-keep class androidx.security.crypto.** { *; }
-keep class com.google.crypto.tink.** { *; }
-keep class com.google.crypto.tink.shaded.protobuf.** { *; }
-dontwarn com.google.crypto.tink.**
-dontwarn androidx.security.**

# ── SnapPark Native (BroadcastReceiver, Service, Widget) ─────────────────
# Manifest 에서 참조하는 클래스는 난독화하면 런타임에 ClassNotFoundException.
-keep class com.snappark.core.receiver.BluetoothDisconnectReceiver { *; }
-keep class com.snappark.core.service.MotionDetectionService { *; }
-keep class com.snappark.core.widget.** { *; }
-keep class com.snappark.core.data.** { *; }
-keep class com.snappark.MainActivity { *; }

# ── JSON / Serialization ────────────────────────────────────────────────
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-keep class * implements java.io.Serializable { *; }

# ── Enum 보존 ────────────────────────────────────────────────────────────
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# ── 디버그 라인 정보 유지 (크래시 리포트용) ──────────────────────────────
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# ── 릴리스 빌드 시 모든 Log 출력 제거 (At-Rest 로그 유출 방지) ─────────
# 앱이 루팅된 기기에서 logcat 으로 민감 정보(MAC, 좌표 등) 노출되지 않도록
# d/v/i/w/e 전부 R8 에 의해 인라인 제거된다. 크래시 로그는 별도 경로로 리포트.
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
    public static int wtf(...);
}
# Kotlin println() 도 릴리스에서 제거 — 개발 중 남긴 임시 출력 방지.
-assumenosideeffects class java.io.PrintStream {
    public void println(%);
    public void println(**);
}

# ── 불필요한 경고 억제 ──────────────────────────────────────────────────
-dontwarn java.lang.invoke.**
-dontwarn javax.annotation.**
-dontwarn org.codehaus.mojo.**
