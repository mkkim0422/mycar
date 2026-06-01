# SnapPark V2 (내차어디) — 인수인계서

> **버전:** 2.0.0+1  
> **작성일:** 2026-04-19  
> **플랫폼:** Android (Flutter + Kotlin Hybrid)  
> **총 코드:** Dart 5,435줄 / Kotlin 1,350줄 / XML 13파일

---

## 1. 프로젝트 개요

### 1.1 목적
복잡한 주차장에서 사용자의 **"인지 부하 제로(Zero Cognitive Load)"** 를 목표로 하는 주차 위치 기록/알림 앱.

### 1.2 핵심 원칙
- **No Mocking:** 더미 데이터 금지. 반드시 로컬 DB 연동된 Repository 패턴 사용.
- **Visual Fidelity:** 레퍼런스 UI와 1:1 픽셀 매칭.
- **Null Safety:** 모든 데이터 모델 Null-safe → 회색 화면(Crash) 원천 차단.
- **Data-First:** DB → Native Bridge → Flutter UI 순서로 구현.

### 1.3 기술 스택
| 영역 | 기술 |
|------|------|
| Frontend | Flutter (Dart 3.0+) |
| Native Android | Kotlin (플러터 연동 전용) |
| Local DB | SharedPreferences (Flutter ↔ Native 공유) |
| Bridge | MethodChannel (`com.snappark/widget`) |
| Widget | Android Native AppWidget (XML RemoteViews) |
| OCR | Google ML Kit Korean Text Recognition |
| 지도 | Naver Map (nmap:// URL Scheme) |
| 공유 | Kakao Flutter SDK Share |

---

## 2. 구현 완료 기능

### 2.1 카메라 & OCR (camera_screen.dart — 973줄)
- 후면 카메라 전체화면 프리뷰
- ML Kit 한국어 OCR로 주차 구역 번호 자동 추출 (B2, A-04 등)
- 번호판 패턴 필터링 (프라이버시 보호)
- 수동 입력 바텀시트 (층/구역 직접 입력)
- 사진 Isolate 복사 (메인 스레드 0ms 블로킹)
- 촬영 시점 GPS 좌표 백그라운드 수집 (비동기, 카메라 UX 미차단)

### 2.2 블루투스 자동 감지 (BluetoothDisconnectReceiver — 191줄)
- OS `ACL_DISCONNECTED` 브로드캐스트 수동 수신 (배터리 소모 0)
- **차량 기기 필터링:** 디바이스 클래스(CAR_AUDIO/HANDSFREE) + Major 클래스(AUDIO_VIDEO) + 키워드(현대/기아/BMW 등)
- **재연결 가드:** `ACL_CONNECTED` 수신 시 서비스 즉시 취소 (BT 연결 시 오알림 방지)
- 앱 종료 상태에서도 동작 (Manifest 선언적 등록)

### 2.3 모션 감지 서비스 (MotionDetectionService — 283줄)
- BT 해제 후 가속도계 기반 "하차 모션" 감지 → < 3초 알림 발송
- 3초 재연결 대기 (Reconnect Guard) → BT 연결/해제 사이클 흡수
- 300ms 베이스라인 수집 → |Δmag| > 1.0 m/s² 시 즉시 알림
- 10초 정지 시 대기 모드 → 다음 모션까지 보류
- 2분 최대 타임아웃 → 무조건 알림 (폰을 차에 놓고 내린 경우)
- Android 14+ `shortService` 타입 (3초 내 종료 시 서비스 알림 미노출)

### 2.4 네이티브 위젯 (ParkingWidgetProvider — 449줄)
- 4가지 사이즈: 2×1, 2×2, 4×2, 4×4
- 3가지 디스플레이 모드: 사진전용 / 위치전용 / 사진+위치
- 위치전용 모드: 10가지 배경색 선택 + luminance 기반 텍스트색 자동 전환
- EXIF 회전 보정 (세로 사진 눕힘 방지)
- 사이즈별 정보 계층:
  - 2×1: 층+구역 + `4/17(목) 오후 3:22`
  - 2×2: 위 + `주차 후 32분 경과`
  - 4×2/4×4: 위 + `4월 17일(목)` 전체 날짜 + 주소
- 위젯 탭 → 앱 홈 화면 or 카메라 직행 (MethodChannel payload)

### 2.5 홈 화면 (home_page.dart — 594줄)
- 최신 주차 기록: 사진 카드 + 구역 + 시간 + 경과시간 + 네이버 지도 바로가기
- 빈 상태: 안내 문구 + 주차 등록 CTA
- 전체화면 사진 뷰어 (핀치줌, FadeTransition)
- 공유 버튼 (구역 텍스트 라인 우측, OS 표준 공유 시트 — share_plus)

### 2.6 주차기록 보기 (parking_history_page.dart — 363줄)
- 전체 주차 기록 리스트 (최신순)
- 체크박스 멀티셀렉트 + 플로팅 삭제 버튼
- 삭제 확인 다이얼로그
- 썸네일 + 날짜/구역/주소 표시
- 빈 상태: "저장된 주차정보가 없습니다"

### 2.7 위젯 설정 (widget_setup_page.dart — 915줄)
- 디스플레이 타입 세그먼트 (위치전용/사진전용/사진+위치)
- 위치전용: 10가지 배경색 선택기
- 4가지 사이즈 샘플 프리뷰 (실제 비율)
- Samsung `requestPinAppWidget` 연동
- 위치전용 시 4×2/4×4 사이즈 숨김

### 2.8 권한 온보딩 (permission_page.dart — 279줄)
- 4가지 권한 순차 요청: 카메라 → 위치 → 블루투스 → 알림
- 거부 시 설정 유도 다이얼로그
- 1회만 표시 (`is_permission_requested` 플래그)
- 기존 사용자: ShellScreen에서 BLUETOOTH_CONNECT 추가 요청

### 2.9 네이버 지도 연동 (map_service.dart — 62줄)
- GPS 좌표 기반 핀 표시 (`nmap://place?lat=&lng=&name=`)
- 주소 검색이 아닌 **정확한 좌표**로 핀 (수십m 오차 제거)
- 앱 미설치 시 웹 폴백 (`map.naver.com/?c=lng,lat,15`)

### 2.10 카카오톡 공유 (kakao_share_service.dart — 140줄)
- FeedTemplate (사진 CDN 업로드 + 리치 카드)
- TextTemplate 폴백 (업로드 실패 시)
- 브라우저 폴백 (카카오톡 미설치 시)

---

## 3. 아키텍처

### 3.1 디렉터리 구조
```
lib/
├── core/
│   ├── config/app_config.dart          — 배포 설정 상수
│   ├── theme/app_theme.dart            — 디자인 토큰
│   └── services/                       — 비즈니스 로직 (6개 서비스)
├── data/
│   ├── models/parking_data.dart        — Freezed 데이터 모델
│   └── repositories/                   — 데이터 접근 계층
└── presentation/
    ├── pages/                          — 화면 (6개 페이지)
    └── widgets/bottom_nav_bar.dart     — 2탭 네비게이션

android/app/src/main/kotlin/com/snappark/
├── MainActivity.kt                     — MethodChannel 허브
├── core/receiver/                      — BT 브로드캐스트 수신
├── core/service/                       — 모션 감지 포그라운드 서비스
├── core/data/                          — SharedPrefs 네이티브 접근
└── core/widget/                        — AppWidget 4종
```

### 3.2 데이터 흐름
```
[카메라 촬영]
  → ParkingRepository.save()
    → SharedPreferences (parking_data + parking_history)
      → MethodChannel "refreshWidget"
        → MainActivity.refreshAllWidgets()
          → 4개 AppWidgetProvider.onUpdate()
            → SharedPrefsHelper.getParkingData()
              → RemoteViews 바인딩
```

### 3.3 BT 알림 흐름
```
[시동 OFF] → OS ACL_DISCONNECTED 브로드캐스트
  → BluetoothDisconnectReceiver.onReceive()
    → isCarDevice() 필터링
      → MotionDetectionService 시작 (3초 재연결 대기)
        → 가속도계 모션 감지
          → 고우선 알림 발송
            → 사용자 탭 → MainActivity (payload: "open_camera")
              → MethodChannel "onPayload" → Flutter /camera 라우팅
```

### 3.4 앱 초기 실행 흐름
```
main()
  → permissionDone 확인
    → false: PermissionPage → 권한 요청 → ShellScreen
      → _checkWidgetSetup() → 위젯 미설정 → WidgetSetupPage 자동 push
    → true: ShellScreen (2탭: 주차등록 + 설정)
```

---

## 4. 저장소 키 맵

| SharedPreferences 키 | 타입 | 용도 | Native 공유 |
|----------------------|------|------|-------------|
| `parking_data` | JSON String | 최신 주차 기록 (홈+위젯) | O |
| `parking_history` | JSON Array | 전체 주차 기록 리스트 | X |
| `widget_display_type` | String | photo_info/photo_only/info_only | O |
| `widget_info_bg_color` | String (#hex) | 위치전용 배경색 | O |
| `is_widget_setup_done` | bool | 위젯 온보딩 완료 여부 | X |
| `is_permission_requested` | bool | 권한 온보딩 완료 여부 | X |
| `instant_trigger_enabled` | bool | 모션 감지 활성화 | X |
| `instant_trigger_threshold` | double | 모션 감지 임계값 (m/s²) | X |

> Flutter `shared_preferences`는 내부적으로 `flutter.` 접두사를 추가.
> Native에서는 `flutter.parking_data` 형태로 접근.

---

## 5. 보안 조치

### 5.1 적용 완료
| 항목 | 설정 | 파일 |
|------|------|------|
| R8/ProGuard 난독화 | `isMinifyEnabled = true` | build.gradle.kts |
| 리소스 축소 | `isShrinkResources = true` | build.gradle.kts |
| ADB 백업 차단 | `android:allowBackup="false"` | AndroidManifest.xml |
| 클라우드 백업 차단 | `android:fullBackupContent="false"` | AndroidManifest.xml |
| HTTP 평문 통신 차단 | `android:usesCleartextTraffic="false"` | AndroidManifest.xml |
| ProGuard 커스텀 규칙 | 60줄 (Native 클래스 보존 등) | proguard-rules.pro |
| 공유 이미지 합성 | 사진 + 글래스 캡션 PNG → ACTION_SEND (kakao SDK 미사용) | kakao_share_service.dart |
| 사진 Isolate 처리 | `compute(_copyFileInIsolate)` | camera_screen.dart |

### 5.2 보안 감사 결과 (전수 검사)
| 항목 | 결과 |
|------|------|
| Race Condition | **0건** — 모든 async gap에 mounted 체크 |
| Memory Leak | **0건** — Controller/Listener 전부 dispose |
| 평문 API 키 | **0건** — 플레이스홀더만 존재 |
| 하드코딩 비밀번호 | **0건** |
| SQL Injection | **해당 없음** — 로컬 SharedPreferences만 사용 |

### 5.3 배포 전 필수 교체
| 항목 | 현재 상태 | 파일 |
|------|----------|------|
| Kakao Native App Key | `'YOUR_KAKAO_NATIVE_APP_KEY'` | app_config.dart:16 |
| Play Store URL | 플레이스홀더 | app_config.dart:20 |
| 서명 키 | debug 키 사용 중 | build.gradle.kts:39 |

---

## 6. 성능 최적화

| 항목 | 적용 내용 |
|------|----------|
| 사진 저장 | `compute()` Isolate에서 파일 복사 (메인 스레드 0ms) |
| 위젯 사진 | `loadScaledBitmap()` 다운샘플링 (max 800px) + EXIF 회전 |
| 카메라 라이프사이클 | `_isProcessing` 가드로 중복 초기화 방지 |
| GPS 조회 | 카메라 촬영과 병렬 실행 (5초 타임아웃) |
| BT 감지 | 수동 BroadcastReceiver (능동 스캔 없음, 배터리 0 소모) |
| 위젯 갱신 | `kotlin.concurrent.thread`로 백그라운드 실행 |
| 이미지 캐시 | `cacheWidth: 1200` / `cacheWidth: 600` 제한 |

---

## 7. Android 권한 매트릭스

| 권한 | 런타임 요청 | 용도 | 거부 시 동작 |
|------|-----------|------|-------------|
| CAMERA | O (permission_page) | 사진 촬영 | 카메라 화면 진입 불가 |
| ACCESS_FINE_LOCATION | O (permission_page) | GPS 좌표 저장 | 좌표 없이 저장 (graceful) |
| BLUETOOTH_CONNECT | O (permission_page) | BT 해제 감지 | 자동 알림 불가 |
| POST_NOTIFICATIONS | O (permission_page) | 푸시 알림 | 알림 미표시 |
| FOREGROUND_SERVICE | 자동 | 모션 감지 서비스 | - |
| FOREGROUND_SERVICE_SHORT_SERVICE | 자동 | Android 14+ | - |

---

## 8. 파일별 줄 수 요약

### Dart (21파일, 5,435줄)
| 파일 | 줄 |
|------|-----|
| camera_screen.dart | 973 |
| widget_setup_page.dart | 915 |
| home_page.dart | 594 |
| parking_history_page.dart | 363 |
| settings_page.dart | 363 |
| parking_data.freezed.dart | 335 (생성) |
| permission_page.dart | 279 |
| ocr_repository.dart | 254 |
| main.dart | 184 |
| widget_settings_service.dart | 151 |
| notification_service.dart | 146 |
| kakao_share_service.dart | 140 |
| parking_repository.dart | 137 |
| app_theme.dart | 125 |
| bottom_nav_bar.dart | 118 |
| location_service.dart | 109 |
| instant_trigger_service.dart | 92 |
| map_service.dart | 62 |
| parking_data.dart | 37 |
| parking_data.g.dart | 29 (생성) |
| app_config.dart | 29 |

### Kotlin (5파일, 1,350줄)
| 파일 | 줄 |
|------|-----|
| ParkingWidgetProvider.kt | 449 |
| MotionDetectionService.kt | 283 |
| MainActivity.kt | 263 |
| BluetoothDisconnectReceiver.kt | 191 |
| SharedPrefsHelper.kt | 164 |

---

## 9. 알려진 제한사항

1. **iOS 미지원** — Android 전용 (AppWidget, BroadcastReceiver 등 Android-only API)
2. **단일 차량** — 차량 BT 기기 등록/관리 UI 없음 (키워드 + 디바이스 클래스로 자동 판별)
3. **오프라인 지도** — 네이버 지도 앱/웹 의존 (인앱 지도 없음)
4. **백업 없음** — 주차 기록이 기기 로컬에만 저장 (클라우드 동기화 없음)
5. **Samsung 최적화** — Samsung One UI 런처 기준으로 위젯 테스트 (타 런처 미검증)

---

## 10. MethodChannel API 레퍼런스

### 채널명: `com.snappark/widget`

| 방향 | 메서드 | 인자 | 설명 |
|------|--------|------|------|
| Dart→Native | `refreshWidget` | 없음 | 설치된 모든 위젯 즉시 갱신 |
| Dart→Native | `pinWidget` | `{size, style?}` | 홈 화면 위젯 고정 요청 |
| Dart→Native | `testMotionTrigger` | 없음 | 모션 감지 서비스 수동 시작 (QA) |
| Native→Dart | `onPayload` | String | `"go_home"` or `"open_camera"` |

---

## 11. Play Store 출시 진행 상태 (2026-05-31 기준)

### ✅ 완료
1. **AdMob 실 ID 적용 + UMP 동의 흐름 + MaxAdContentRating.pg** (commit 0502100, 574ce3a)
2. **공유 기능 최종 형태**:
   - 카카오 SDK 제거 → `share_plus` (Intent.ACTION_SEND) 로 전환
   - 사진 + 텍스트 통합: 사진 하단에 iOS 글래스모피즘 캡션 카드(`ImageFilter.blur`) 합성한 PNG 한 장 전송
   - 공유 버튼은 사진 위 오버레이가 아닌 **구역 텍스트 라인 우측 ghost 아이콘** 배치 (사진 탭 충돌 방지)
   - `kakao_share_service.dart` 클래스명은 호출부 호환을 위해 유지, 내부 구현만 share_plus
3. **약관 정비**: 책임자 → "운영자" + `mkkim850422@gmail.com`. 회사 이메일 약관에서 전부 제거. "회사" → "운영자" 일괄
4. **알림 아이콘**: `drawable/ic_notification.xml` 신규 (Material `local_parking` 흰색 단색 실루엣). Dart + Native 3곳 동시 교체. R8 minify 통과 확인
5. **업로드 서명키 생성**: alias=upload, validity 25년. `build.gradle.kts` 의 `signingConfigs.release.storeFile` 은 `rootProject.file(...)` 사용 (android/ 폴더 기준)
6. **release AAB 빌드**: `build/app/outputs/bundle/release/app-release.aab` (72.1MB)
   - 업로드 인증서 SHA-1: `40:DB:5B:EC:48:A4:98:1A:9B:20:D6:63:39:59:0D:0D:AE:00:DF:5E`
   - 업로드 인증서 SHA-256: `A7:B6:38:5E:5D:54:FF:B6:69:3A:8E:21:DE:EA:D0:FA:36:B7:86:BC:19:FC:3C:23:C3:D2:63:B4:03:89:20:16`

### ⏭️ 남은 작업 (Play Console 웹에서 수동)
1. Play Console 접속 → 앱 등록 (`com.snappark`)
2. AAB 업로드
3. 메타데이터: 스크린샷·앱 설명·앱 아이콘·카테고리 등
4. 인앱상품 `remove_ads` 비소비성 ₩1,900 등록
5. 개인정보처리방침 호스팅 URL (GitHub Gist 추천) → Play Console 에 URL 입력
6. 심사 제출

---

## 12. 다른 PC 에서 이어가기 (Setup 가이드)

### ⚠️ 깃으로 안 옮겨지는 파일들 (gitignored — 수동 복사 필수)
| 파일 | 경로 | 내용 | 분실 영향 |
|------|------|------|----------|
| `app_config.dart` | `lib/core/config/app_config.dart` | AdMob 실 배너 ID + Kakao REST API 키 | 광고 미노출 / 역지오코딩 폴백 |
| `snappark-upload.jks` | `android/snappark-upload.jks` | **업로드 서명키** | **앱 업데이트 영구 불가** |
| `key.properties` | `android/key.properties` | 서명키 비밀번호 평문 | 위와 같음 |

→ 위 3개 파일은 **반드시 USB/클라우드(개인 Google Drive 등) 로 직접 옮겨야** 한다. 깃에 안 올라간다.

### Setup 절차

```
1. 새 PC 에 도구 설치
   - Flutter SDK (3.x 이상, 현재 PC 와 동일 버전 권장)
   - Android Studio (JDK + Android SDK + keytool 포함)
   - Java 17 (Android Studio 의 jbr 사용)
   - Git

2. 저장소 클론
   git clone https://github.com/mkkim0422/mycar.git
   cd mycar

3. 위 gitignored 3개 파일 복사 붙여넣기
   - lib/core/config/app_config.dart
   - android/snappark-upload.jks
   - android/key.properties

4. 의존성 설치
   flutter pub get

5. 검증 빌드 (release)
   flutter build appbundle --release
   → build/app/outputs/bundle/release/app-release.aab 생성되면 정상

6. (선택) 서명 검증
   cd android
   ./gradlew.bat signingReport
   → release variant SHA-1 이 위 문서의 fingerprint 와 일치하는지 확인
```

### 다음 작업 진입점
**Play Console 업로드** — 위 §11 의 "남은 작업" 1~6 단계 진행. 코드 변경 없음, Play Console 웹에서만.

### 다음 세션의 Claude 에게
- `MEMORY.md` 의 `[project-release-prep-status]` 메모리는 이 PC 에만 있다. 새 PC 에서 시작 시 본 문서(특히 §11~§12)를 먼저 읽고 거기 기록된 진행 상태를 메모리에 다시 적어둘 것
- AdMob 실 ID, Kakao 키, keystore SHA-1 등 식별값은 위에 다 기재되어 있다

---

*이 문서는 프로젝트의 현재 상태를 완전히 기술하며, 다음 개발자가 코드베이스를 이해하고 유지보수할 수 있도록 작성되었습니다.*
