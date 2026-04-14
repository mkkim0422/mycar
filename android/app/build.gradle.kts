plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter Gradle Plugin은 Android/Kotlin 플러그인 이후에 적용해야 한다.
    id("dev.flutter.flutter-gradle-plugin")
}

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
    }

    buildTypes {
        release {
            // 배포 시 별도 서명 설정 필요. 현재는 디버그 키로 flutter run --release 동작.
            signingConfig = signingConfigs.getByName("debug")
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
}
