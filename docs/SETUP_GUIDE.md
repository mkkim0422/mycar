# 네이티브 설정 가이드 — Google ML Kit OCR

## 1. pubspec.yaml 의존성

```yaml
dependencies:
  flutter:
    sdk: flutter
  camera: ^0.11.0+2
  google_mlkit_text_recognition: ^0.13.0
```

> `image`, `image_cropping` 등 픽셀 조작 패키지는 **절대 추가하지 마십시오.**
> UI 스레드 멈춤(Freezing)의 원인이 됩니다.

---

## 2. Android 설정

### 2-1. `android/app/build.gradle`

```groovy
android {
    // ML Kit은 minSdk 21 이상 필요
    defaultConfig {
        minSdkVersion 21
        targetSdkVersion 34

        // ★ 핵심: 필요한 ML Kit 모델만 포함하여 APK 크기 최적화
        // ndk { abiFilters 'armeabi-v7a', 'arm64-v8a' }  // 선택사항
    }
}
```

### 2-2. `android/app/src/main/AndroidManifest.xml`

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- 카메라 권한 -->
    <uses-permission android:name="android.permission.CAMERA" />

    <!-- ML Kit 모델 자동 다운로드 (Google Play 기기에서 on-demand) -->
    <application>
        <meta-data
            android:name="com.google.mlkit.vision.DEPENDENCIES"
            android:value="ocr_korean" />

        <!-- 기존 activity 선언 아래에 추가 -->
    </application>
</manifest>
```

### 2-3. `android/build.gradle` (프로젝트 레벨)

```groovy
buildscript {
    // Kotlin 버전 1.8.0 이상 확인
    ext.kotlin_version = '1.9.0'
}
```

### 2-4. `android/gradle.properties`

```properties
# ML Kit은 AndroidX 필수
android.useAndroidX=true
android.enableJetifier=true
```

---

## 3. iOS 설정

### 3-1. `ios/Podfile`

```ruby
platform :ios, '15.5.0'  # ML Kit은 iOS 15.5.0 이상 권장

# ...

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.5.0'
  end
end
```

### 3-2. `ios/Runner/Info.plist`

```xml
<dict>
    <!-- 카메라 사용 권한 설명 (필수: 미입력 시 앱 심사 거부) -->
    <key>NSCameraUsageDescription</key>
    <string>주차 구역 번호를 인식하기 위해 카메라를 사용합니다.</string>
</dict>
```

### 3-3. Pod 설치

```bash
cd ios
pod install --repo-update
cd ..
```

---

## 4. 권한 요청 (런타임)

앱 최초 진입 시 `permission_handler` 패키지 또는 직접 구현으로
카메라 권한을 요청해야 합니다. `OcrCameraScreen` 진입 전에 처리하세요:

```dart
// main.dart 또는 진입 화면에서
import 'package:permission_handler/permission_handler.dart';

Future<void> _requestCameraPermission() async {
  final status = await Permission.camera.request();
  if (status.isGranted) {
    // OcrCameraScreen으로 이동
    Navigator.push(context,
      MaterialPageRoute(builder: (_) => const OcrCameraScreen()));
  }
}
```

> `permission_handler`를 사용할 경우 pubspec.yaml에 추가:
> ```yaml
> dependencies:
>   permission_handler: ^11.0.0
> ```

---

## 5. 좌표 변환 검증 체크리스트

배포 전 아래 시나리오를 반드시 실기기에서 테스트하십시오:

| # | 테스트 항목 | 확인 사항 |
|---|-----------|----------|
| 1 | Android 세로 모드 촬영 | sensorOrientation=90° 회전 보정 정상 |
| 2 | iOS 세로 모드 촬영 | EXIF 자동 적용 시 rotation=0° 처리 정상 |
| 3 | 가이드라인 중앙의 텍스트 | 인식 후 정확히 필터링되는지 |
| 4 | 가이드라인 밖의 텍스트 | 무시되는지 (광고판, 바닥 문자 등) |
| 5 | 비율 4:3 카메라 | Letterbox 오프셋 계산 정상 |
| 6 | 비율 16:9 카메라 | 다른 비율에서도 정상 동작 |
| 7 | UI 프리징 | 촬영~결과 표시까지 화면 멈춤 없음 |

---

## 6. 흔한 빌드 오류 해결

### "Minimum deployment target" (iOS)
→ Podfile의 `platform :ios` 버전을 `15.5.0` 이상으로 올리세요.

### "Namespace not specified" (Android)
→ `android/app/build.gradle`에 `namespace` 확인:
```groovy
android {
    namespace "com.yourapp.naechaeodi"
}
```

### "ML Kit model not found"
→ AndroidManifest.xml의 `com.google.mlkit.vision.DEPENDENCIES` 메타데이터 확인.
→ 첫 실행 시 모델 다운로드에 수 초 소요될 수 있음 (Wi-Fi 권장).
