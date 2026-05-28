import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter Gradle Plugin은 Android/Kotlin 플러그인 이후에 적용해야 한다.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 릴리스 업로드 키 (Play 앱 서명) ──────────────────────────────────────────
// android/key.properties 가 있으면 그 값으로 release 를 서명한다(스토어 업로드용).
// 파일이 없으면(개발 PC·CI) release 도 debug 키로 폴백 → flutter run --release 정상.
// key.properties 와 *.jks 는 .gitignore 로 커밋 차단됨(비밀번호 노출 방지).
val keystorePropertiesFile = rootProject.file("key.properties")
val hasUploadKey = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasUploadKey) load(FileInputStream(keystorePropertiesFile))
}

// ── AdMob 앱 ID ──────────────────────────────────────────────────────────────
// 단일 소스: 여기 2개 상수 → manifestPlaceholders → AndroidManifest 의 ${admobAppId}.
// debug 는 Google 공식 테스트 앱 ID(정책상 안전), release 는 실제 앱 ID 를 써야 한다.
// 실제 앱 ID 발급 전까지 크래시 방지를 위해 release 도 테스트 앱 ID 로 둔다.
// 실제 광고 노출 자체는 AppConfig.admobRealBannerUnitId 가 설정될 때까지
// (Dart 측에서) 배너를 숨겨 차단하므로, 테스트 광고가 운영 배포로 나가지 않는다.
val admobTestAppId = "ca-app-pub-3940256099942544~3347511713" // 공식 테스트 — 변경 금지
// AdMob 콘솔에서 발급받은 "주차기억" 앱 ID. release 빌드에 주입된다.
val admobRealAppId = "ca-app-pub-3708412629376493~3704557856"

android {
    namespace = "com.snappark"
    compileSdk = 36  // camera_android_camerax, shared_preferences_android 등 요구사항
    ndkVersion = "28.2.13676358"  // jni 플러그인 요구사항 (27.x 상위 호환)

    compileOptions {
        // flutter_local_notifications: Java 8+ Time API 역직렬화 지원 필요
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.snappark"

        // camera_android_camerax 최소 요구사항: API 21
        // flutter.minSdkVersion(24) 대신 21을 명시하여 더 넓은 기기 지원
        minSdk = flutter.minSdkVersion
        targetSdk = 36

        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 안전 기본값: 테스트 앱 ID. 명시 override 없는 buildType(=debug)은
        // 자동으로 테스트 광고로 떨어진다. release 는 아래에서 override.
        manifestPlaceholders["admobAppId"] = admobTestAppId
    }

    signingConfigs {
        // 업로드 키스토어(key.properties)가 있을 때만 release 서명을 구성한다.
        if (hasUploadKey) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // buildType 별 AdMob 앱 ID 주입(테스트/실제 구조적 분리).
            manifestPlaceholders["admobAppId"] = admobRealAppId

            // key.properties 있으면 업로드 키로 서명(Play 업로드 가능),
            // 없으면 debug 키 폴백(로컬/CI 에서 release 빌드가 깨지지 않게).
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // 릴리스 빌드 디버그 비활성화
            isDebuggable = false

            // ── R8/ProGuard 난독화 + 코드 축소 ────────────────────────
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 로컬 푸시 알림 (flutter_local_notifications가 Java 코드에서 사용)
    implementation("androidx.core:core-ktx:1.15.0")
    // Java 8+ API desugaring (flutter_local_notifications 요구사항)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // ML Kit 한글 OCR — google_mlkit_text_recognition 플러그인이 Korean script 사용 시
    // KoreanTextRecognizerOptions 네이티브 클래스가 필요하다.
    // 누락 시: java.lang.NoClassDefFoundError 로 촬영 직후 크래시.
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")

    // EXIF orientation 읽기 (위젯 사진 회전 복원용).
    // BitmapFactory.decodeFile 은 EXIF 를 무시하므로 ExifInterface 로 회전값을 읽어
    // Matrix 로 bitmap 을 돌려야 큰 사이즈 위젯에서 사진이 눕지 않는다.
    implementation("androidx.exifinterface:exifinterface:1.3.7")

    // ── AndroidX Security (At-Rest 암호화) ──────────────────────────────────
    // AndroidKeyStore 로 보호되는 마스터 키를 이용해 SharedPreferences 를 AES-GCM
    // 로 암호화한다. BluetoothDisconnectReceiver 가 앱 종료 상태에서도 BT MAC 을
    // 복호화해야 하므로 Flutter 플러그인 대신 네이티브에서 직접 소유한다.
    //
    // 저장 대상:
    //   - manual_car_id        : 수동 태깅된 차량 BT 기기 MAC
    //   - manual_car_id_name   : 표시용 기기 이름
    //
    // 대상 파일: 내부 스토리지 /data/data/com.snappark/shared_prefs/SnapParkSecurePrefs.xml
    //          (키·값 모두 AES-SIV/AES-GCM 암호화. 루팅된 디바이스에서도 평문 노출 없음)
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
}
