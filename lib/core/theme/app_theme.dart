import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// SnapPark V2 디자인 토큰.
/// '내차어디' 레퍼런스 1:1 픽셀 매칭을 위한 컬러 / 타이포그래피 / 스페이싱 상수.
class AppTheme {
  AppTheme._();

  // ── Color Palette ──────────────────────────────────────────────────────────
  static const Color tossBlue   = Color(0xFF0064FF); // Primary CTA
  static const Color gray100    = Color(0xFFF7F8FA); // Scaffold / 카드 배경
  static const Color gray200    = Color(0xFFE5E8EB); // 구분선, 테두리
  static const Color gray500    = Color(0xFF8B95A1); // 보조 텍스트
  static const Color gray900    = Color(0xFF191F28); // 기본 텍스트 (검정에 가까운 다크)
  static const Color white      = Color(0xFFFFFFFF);

  // ── Typography Scale (sp 단위 = Flutter의 논리적 px과 동일) ──────────────
  static const double fontDisplay  = 34.0; // 주차 구역 대형 타이틀
  static const double fontTitle    = 20.0; // AppBar 타이틀
  static const double fontBody1    = 16.0; // 기본 본문, 시간 레이블
  static const double fontCaption  = 13.0; // 보조 레이블

  // ── Spacing ────────────────────────────────────────────────────────────────
  static const double spacingPage  = 20.0; // 페이지 좌우 패딩
  static const double spacingCard  = 24.0; // 카드 내부 패딩

  // ── Border Radius ──────────────────────────────────────────────────────────
  static const double radiusImage  = 28.0; // Full-bleed 이미지 카드
  static const double radiusCard   = 20.0; // 일반 카드
  static const double radiusButton = 28.0; // 주요 버튼
  static const double radiusChip   = 12.0; // 소형 칩

  // ── Button Heights ─────────────────────────────────────────────────────────
  static const double btnPrimary   = 60.0; // 하단 CTA 버튼
  static const double navBarHeight = 78.0; // 하단 내비게이션

  // ── Light Theme ───────────────────────────────────────────────────────────
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: tossBlue,
          primary: tossBlue,
          surface: white,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: gray100,

        // AppBar: 투명, 상태바는 다크 아이콘
        appBarTheme: const AppBarTheme(
          backgroundColor: gray100,
          foregroundColor: gray900,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: gray900,
            fontSize: fontTitle,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
          ),
        ),

        // 기본 텍스트 테마
        textTheme: const TextTheme(
          // 주차 구역 대형 텍스트
          displayLarge: TextStyle(
            fontSize: fontDisplay,
            fontWeight: FontWeight.w900,
            color: gray900,
            letterSpacing: -1.0,
            height: 1.15,
          ),
          // 섹션 타이틀
          titleLarge: TextStyle(
            fontSize: fontTitle,
            fontWeight: FontWeight.w700,
            color: gray900,
            letterSpacing: -0.4,
          ),
          // 본문 · 시간 텍스트
          bodyLarge: TextStyle(
            fontSize: fontBody1,
            fontWeight: FontWeight.w500,
            color: gray500,
            letterSpacing: -0.2,
          ),
          // 보조 레이블
          bodySmall: TextStyle(
            fontSize: fontCaption,
            fontWeight: FontWeight.w500,
            color: gray500,
            letterSpacing: 0,
          ),
        ),

        // ElevatedButton 기본 스타일 (필요 시 사용)
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: tossBlue,
            foregroundColor: white,
            minimumSize: const Size.fromHeight(btnPrimary),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusButton),
            ),
            elevation: 0,
            textStyle: const TextStyle(
              fontSize: fontBody1,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),

        // 구분선
        dividerTheme: const DividerThemeData(
          color: gray200,
          thickness: 1,
          space: 0,
        ),
      );
}
