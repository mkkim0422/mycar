# SnapPark(내차어디) v1.0.4+5 릴리스 노트

날짜: 2026-08-06
브랜치: `feature/ocr-parking-zone`

## 배경

Google Play Console 정책 권고 대응 릴리스.

> "2026년 8월 31일부터 모든 앱은 Google Play Billing Library 8.0.0 버전 이상을
> 사용해야 합니다. 업데이트가 거부되지 않도록 이 날짜까지 최신 버전으로
> 업데이트하세요."

기존 앱은 `in_app_purchase 3.2.3` → `in_app_purchase_android 0.4.0+11`
→ **Play Billing Library 7.x** 를 내장하고 있어 마감일 이후 업데이트가
거부될 상태였다.

## 변경 사항

### 1. Google Play Billing Library 8.0.0 업그레이드 (정책 대응, 필수)

- `pubspec.yaml`: `in_app_purchase ^3.2.3` → `^3.3.0`
- 잠금 결과: `in_app_purchase 3.3.0` / `in_app_purchase_android 0.5.0`
- `in_app_purchase_android 0.5.0` 은 `com.android.billingclient:billing:8.0.0`
  을 직접 선언 (플러그인 CHANGELOG: "Updates Google Play Billing Library
  from 7.1.1 to 8.0.0") — 요구사항 충족 확인.
- Dart API 변경 없음: `billing_service.dart` 수정 불필요, `flutter analyze`
  이슈 0건.
- 앱 gradle(compileSdk 36 / targetSdk 36 / minSdk flutter 기본)은 Billing 8
  요건과 충돌 없음. 앱 측 직접 billingclient 의존성 없음(플러그인 경유 단일).

### 2. 카메라 촬영 셔터랙(딜레이) 패치

파일: `lib/presentation/pages/camera_screen.dart`

- **플래시 off 고정**: camera 플러그인 기본 플래시 모드(auto)는 어두운
  주차장에서 `takePicture()` 호출마다 플래시 측광(precapture) 시퀀스를
  수행해 1~2초의 셔터랙을 만들었다. 카메라 초기화 시
  `setFlashMode(FlashMode.off)` 로 고정해 제거. 라이브 OCR 은 원래
  무플래시 프리뷰 프레임으로 동작하므로 인식률 영향 없음.
  (플래시 미지원 기기는 try/catch 로 무시)
- **햅틱 비동기화**: 셔터 탭 시 `await HapticFeedback.mediumImpact()` 가
  촬영 시작을 막고 있어 `unawaited(...)` 로 변경.
- 유지한 것: 셔터의 300ms 쿨타임(스트림 정지 후 안정화 목적)과 바이트 수준
  EXIF 제거(이미 수 ms)는 그대로 둠. 패치 후에도 느리면 쿨타임 축소를
  기기 테스트와 함께 검토.

### 3. 버전

- `1.0.3+4` → **`1.0.4+5`** (versionName 1.0.4 / versionCode 5)

## Play Console 출시 노트 (ko-KR, 붙여넣기용)

```
<ko-KR>
• 사진 촬영 속도 개선 — 셔터를 누르면 즉시 찍히도록 촬영 지연을 크게 줄였습니다.
• 결제 모듈을 최신 Google Play 기준(Billing Library 8)으로 업데이트했습니다.
• 안정성 개선 및 내부 최적화.
</ko-KR>
```

## 배포 절차

1. `flutter build appbundle --release`
   → `build/app/outputs/bundle/release/app-release.aab`
2. Play Console → 프로덕션(또는 활성 게시 트랙) → 새 버전 만들기
3. `app-release.aab` 업로드 (versionCode 5)
4. 위 출시 노트 붙여넣기 → 검토 → 출시
5. 출시 후 정책 페이지에서 "Billing Library 요구사항" 경고가 해소됐다는
   알림 수신 확인 (심사·전파에 며칠 걸릴 수 있음)

## 검증 기록

- `flutter analyze` — No issues found (업그레이드 전/후 모두)
- `flutter build appbundle --release` — 빌드 성공 확인 후 업로드
- 실기기 확인 권장 항목:
  - 설정 화면 "광고 제거" 가격 정상 표시 (Billing 8 연결 확인)
  - 광고 제거 구매/복원 플로우 (내부 테스트 트랙에서)
  - 어두운 주차장에서 셔터 반응 속도 체감 확인
