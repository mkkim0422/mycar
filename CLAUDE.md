# Project: SnapPark V2 (내차어디 프리미엄)

## 1. Project Philosophy & Goal
- 본 프로젝트는 복잡한 주차장에서 사용자의 "인지 부하 제로(Zero Cognitive Load)"를 목표로 하는 주차 위치 기록/알림 앱이다.
- 디자인 원칙: 사용자가 제공한 '내차어디' 레퍼런스 UI와 1:1 픽셀 매칭을 최우선으로 한다. (기능 없는 예쁜 UI 금지, 임의의 디자인 변경 금지)
- 아키텍처 원칙: 기능(Data/Native)이 작동하지 않는 UI(Flutter 껍데기)는 만들지 않는다. 반드시 '데이터 파이프라인'을 먼저 연결하고 UI를 씌운다.

## 2. Tech Stack
- Frontend: Flutter (Dart)
- Native Android: Kotlin (플러터 연동 전용으로 사용)
- Local DB: SharedPreferences 또는 SQflite/Room (가장 가볍고 빠른 방식 채택)
- Bridge: MethodChannel, EventChannel
- Widget: Android Native AppWidget (Glance 또는 XML 기반)

## 3. Core Features (4대 핵심 로직)
1. 스마트 OCR: 카메라 촬영 시 번호판 패턴은 무시하고 '주차 구역 번호(예: B2, A-04)'만 추출.
2. 자동화 트리거: 차량 Bluetooth 연결 해제 시 백그라운드에서 감지하여 푸시 알림 & 기압 센서로 층수 추측.
3. 네이티브 위젯: Flutter 뷰가 아닌, Android Native 기반의 2x1, 2x2, 4x4 'Full-bleed(사진 꽉 참)' 위젯 구현 및 실시간 데이터 동기화.
4. 카카오톡 공유: 추출된 위치 텍스트와 사진을 카카오톡 템플릿으로 전송.

## 4. Claude Coding Rules (Strict)
- [No Mocking]: UI를 그릴 때 더미(Dummy) 데이터를 박아두고 끝내지 마라. 반드시 로컬 DB에서 불러오는 Repository 패턴을 연결하라.
- [Visual Fidelity]: 폰트 사이즈(sp), 굵기(Weight), 색상(#0064FF, #8B95A1) 등은 지시된 레퍼런스를 1:1로 구현하라.
- [Null Safety]: 모든 데이터 모델은 Null-safe하게 설계하여 회색 화면(Crash)을 원천 차단하라.
- [Step-by-Step]: 한 번에 모든 것을 짜지 마라. DB -> Native Bridge -> Flutter UI 순서로 계통을 하나씩 확실히 점검하며 진행하라.
