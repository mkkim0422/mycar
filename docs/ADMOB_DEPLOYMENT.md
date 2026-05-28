# AdMob 배포 체크리스트

코드 측 설정은 모두 완료된 상태입니다. 아래는 **AdMob 콘솔 / 개발자 사이트 / iOS** 에서 직접 처리해야 할 외부 작업 목록입니다.

## 1. AdMob 콘솔 설정 (필수)

### 1-1. app-ads.txt 게시

AdMob 수익 인벤토리 보호를 위해 개발자 도메인에 `app-ads.txt` 파일을 게시해야 합니다.

1. AdMob 콘솔 → 앱 → "주차기억" → 앱 설정 → **app-ads.txt** 메뉴
2. 표시된 1줄(예: `google.com, pub-3708412629376493, DIRECT, f08c47fec0942fa0`) 복사
3. Play Console 에 등록된 개발자 사이트(예: `https://sphinfo.co.kr`)의 **루트 경로**에 `app-ads.txt` 파일 업로드
   - 최종 URL: `https://sphinfo.co.kr/app-ads.txt`
4. 콘솔에서 [확인] → 24~48 시간 내 "인증됨" 상태로 전환

> 미게시 시: 일부 광고 인벤토리에서 입찰 제외 → 수익 감소 (정책 위반은 아님)

### 1-2. GDPR 동의 메시지(UMP) 생성

코드는 이미 `ConsentInformation` API 를 호출 중이지만, **콘솔에서 메시지를 생성하지 않으면 EEA 사용자에게 양식이 표시되지 않습니다.**

1. AdMob 콘솔 → 개인정보 보호 및 메시징 → **GDPR**
2. "메시지 만들기" → 언어: 한국어 + 영어 → 자동 생성된 양식 검토 후 게시
3. 동일하게 "기타 지역 (미국 주별 법률)" 도 생성 권장(캘리포니아 등)

> 게시 후 EEA/UK/스위스 IP 사용자 최초 실행 시 자동으로 양식이 표시됩니다.

## 2. iOS 광고 활성화 (현재 비활성, 추후 작업)

iOS 빌드에 광고를 실제 노출하려면 다음 작업이 필요합니다.

### 2-1. 코드 — 가드 해제

`lib/presentation/widgets/ad_banner.dart:73-76`
```dart
if (!Platform.isAndroid) {
  _dismiss();
  return;
}
```
→ iOS 가드 제거 (이미 GADApplicationIdentifier 는 Info.plist 에 사전 설정됨)

`lib/main.dart` — `if (Platform.isAndroid)` 가드 해제

### 2-2. Info.plist — SKAdNetworkItems 추가

iOS 14.5+ SKAdNetwork 어트리뷰션을 위해 Google 권장 네트워크 ID 목록 추가:
- 공식 목록: https://developers.google.com/admob/ios/quick-start#update_your_infoplist
- 약 70 개 항목 (Google + 광고 네트워크 파트너)

### 2-3. Info.plist — App Tracking Transparency

```xml
<key>NSUserTrackingUsageDescription</key>
<string>맞춤형 광고 제공을 위해 광고 식별자 사용 동의가 필요합니다. 거부해도 비개인화 광고는 계속 표시됩니다.</string>
```

### 2-4. ATT 권한 요청 코드 추가

`google_mobile_ads` 패키지의 `AppTrackingTransparency` 또는 별도 `app_tracking_transparency` 패키지로 IDFA 권한 요청 흐름 구현.

## 3. Play Console — 광고 제거 인앱 상품 등록

`AppConfig.removeAdsProductId = 'remove_ads'` 와 동일한 상품 등록 필요:

1. Play Console → 수익 창출 → **인앱 상품**
2. 상품 만들기 → ID: `remove_ads` (코드와 정확히 일치)
3. 유형: **관리 상품(비소비성)**
4. 가격: ₩1,900 (또는 원하는 가격)
5. 설명/제목 작성 후 활성화

> 미등록 시: 결제 버튼 동작 안 함, 가격은 폴백(₩1,900)으로 표시.

## 4. AdMob 정책 자가 점검 (제출 전)

- [ ] 테스트 광고로 본인 클릭 0 회 (계정 정지 사유 1순위)
- [ ] 실제 광고로 본인 클릭 0 회
- [ ] 한 화면에 배너 1 개 (현재: 홈 하단 1 개 ✓)
- [ ] 액션 버튼과 배너 사이 48dp 이상 (현재: ✓)
- [ ] 콘텐츠 없는 화면(splash, 로딩)에 광고 미노출 (현재: ✓)
- [ ] 가족용/아동 콘텐츠 아님 명시 (max content rating: PG, 현재: ✓)
- [ ] 개인정보처리방침에 AdMob 명시 (현재: ✓)
- [ ] app-ads.txt 게시 (위 1-1 작업)
- [ ] GDPR 동의 메시지 게시 (위 1-2 작업)

## 5. 출시 후 모니터링

- AdMob 콘솔 → "정책 센터" 정기 확인 (정책 위반 알림)
- "최적화" 탭의 권장 사항 검토(eCPM 향상)
- 광고 노출률 / 클릭률(CTR) 비정상 시 즉시 조사 (CTR > 10% 면 클릭 어뷰즈 의심)
