import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/widget_settings_service.dart';
import '../../core/theme/app_theme.dart';

/// ── 디자인 토큰 ─────────────────────────────────────────────────────────────
const _ctaGradient = LinearGradient(
  begin: Alignment.centerLeft,
  end: Alignment.centerRight,
  colors: [Color(0xFF0064FF), Color(0xFF7C5CFC)],
);

// ── 위치전용 모드 배경색 옵션 (10가지) ──────────────────────────────────────
class _InfoColor {
  final Color color;
  final String hex; // '#RRGGBB' — SharedPrefs / Kotlin 에 저장
  final bool isDark; // true → 흰 텍스트, false → 어두운 텍스트

  const _InfoColor(this.color, this.hex, {this.isDark = true});

  Color get textColor =>
      isDark ? Colors.white : const Color(0xFF1B1D21);
  Color get subTextColor =>
      isDark
          ? Colors.white.withValues(alpha: 0.85)
          : const Color(0xFF1B1D21).withValues(alpha: 0.65);
}

const _infoColorOptions = <_InfoColor>[
  _InfoColor(Color(0xFF0064FF), '#0064FF'),                        // Toss Blue
  _InfoColor(Color(0xFF1B1D21), '#1B1D21'),                        // Charcoal
  _InfoColor(Color(0xFF1A3A5C), '#1A3A5C'),                        // Navy
  _InfoColor(Color(0xFF2B8A3E), '#2B8A3E'),                        // Forest Green
  _InfoColor(Color(0xFF7048E8), '#7048E8'),                        // Purple
  _InfoColor(Color(0xFFE03131), '#E03131'),                        // Red
  _InfoColor(Color(0xFFE8590C), '#E8590C'),                        // Orange
  _InfoColor(Color(0xFF0B7285), '#0B7285'),                        // Teal
  _InfoColor(Color(0xFFFFFFFF), '#FFFFFF', isDark: false),         // White
  _InfoColor(Color(0xFFE8F4FD), '#E8F4FD', isDark: false),        // Sky Blue
];

_InfoColor _findColor(String hex) =>
    _infoColorOptions.firstWhere((c) => c.hex == hex,
        orElse: () => _infoColorOptions.first);

/// 홈 화면 위젯 설정 페이지.
class WidgetSetupPage extends StatefulWidget {
  const WidgetSetupPage({super.key});

  @override
  State<WidgetSetupPage> createState() => _WidgetSetupPageState();
}

class _WidgetSetupPageState extends State<WidgetSetupPage> {
  // 사진+위치 단일 스타일로 고정. 위치전용 / 사진전용 탭은 제거됨.
  static const WidgetDisplayType _style = WidgetDisplayType.photoInfo;

  WidgetSize? _selected;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    // 기존 설정값은 무시 — 스타일은 photoInfo 로 강제 고정.
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _onConfirm() async {
    final size = _selected;
    if (size == null || _busy) return;
    setState(() => _busy = true);

    await WidgetSettingsService.setType(_style);
    await WidgetSettingsService.markSetupDone();

    final result = await WidgetSettingsService.pinWidget(size, style: _style);

    if (!mounted) return;
    setState(() => _busy = false);

    switch (result) {
      case PinWidgetResult.requested:
        // pin 요청이 OS 에 전달됐다 → 이 페이지의 임무는 완료.
        // 1) 스택에서 widget-setup 을 제거해 다음 foreground 복귀 시 Shell 로 바로
        //    돌아가게 한다. (위젯 탭 → 카메라 → 저장 후 Shell 로 복귀 보장)
        // 2) 앱을 백그라운드로 내려 사용자가 홈 화면에서 위치를 직접 고르거나
        //    시스템 "추가" 팝업을 확인할 수 있게 한다.
        if (mounted) Navigator.of(context).maybePop();
        await WidgetSettingsService.moveAppToBackground();
        break;
      case PinWidgetResult.unsupported:
      case PinWidgetResult.error:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('자동 추가가 지원되지 않는 런처입니다.\n'
                '홈 화면을 길게 누르고 "내차어디"를 찾아 추가해 주세요'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
        break;
    }
  }

  void _select(WidgetSize size) {
    setState(() => _selected = size);
  }

  @override
  Widget build(BuildContext context) {
    // 사진+위치 고정 모드이므로 infoOnly 관련 분기는 모두 제거됨.
    final colorOpt = _findColor('#0064FF');

    return Scaffold(
      backgroundColor: AppTheme.gray100,
      appBar: AppBar(
        backgroundColor: AppTheme.gray100,
        title: const Text('위젯 선택'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.tossBlue),
            )
          : SafeArea(
              top: false,
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                      children: [
                        const Text(
                          '홈 화면에 추가할 위젯 크기를 선택하세요.\n'
                          '위젯을 통해 주차 위치를 빠르게 확인할 수 있어요.',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppTheme.gray500,
                            height: 1.55,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 18),

                        // 스타일 세그먼트(위치전용/사진전용/사진+위치) 제거됨.
                        // 앱은 '사진+위치' 단일 스타일만 제공한다.

                        // ── 2×1 + 2×2 나란히 ─────────────────────────
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _SampleTile(
                                size: WidgetSize.size2x1,
                                sizeLabel: '2×1 위젯',
                                style: _style,
                                colorOpt: colorOpt,
                                photoPath: null,
                                selected: _selected == WidgetSize.size2x1,
                                onTap: () => _select(WidgetSize.size2x1),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _SampleTile(
                                size: WidgetSize.size2x2,
                                sizeLabel: '2×2 위젯',
                                style: _style,
                                colorOpt: colorOpt,
                                photoPath: null,
                                selected: _selected == WidgetSize.size2x2,
                                onTap: () => _select(WidgetSize.size2x2),
                              ),
                            ),
                          ],
                        ),

                        // ── 4×2 ─────────────────────────────────────
                        const SizedBox(height: 22),
                        _SampleTile(
                          size: WidgetSize.size4x2,
                          sizeLabel: '4×2 위젯',
                          style: _style,
                          colorOpt: colorOpt,
                          photoPath: null,
                          selected: _selected == WidgetSize.size4x2,
                          onTap: () => _select(WidgetSize.size4x2),
                        ),

                        // ── 4×4 ─────────────────────────────────────
                        const SizedBox(height: 22),
                        _SampleTile(
                          size: WidgetSize.size4x4,
                          sizeLabel: '4×4 위젯',
                          style: _style,
                          colorOpt: colorOpt,
                          photoPath: null,
                          selected: _selected == WidgetSize.size4x4,
                          onTap: () => _select(WidgetSize.size4x4),
                        ),
                      ],
                    ),
                  ),

                  // ── 하단 고정 CTA ──────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _AddButton(
                          enabled: _selected != null && !_busy,
                          busy: _busy,
                          onTap: _onConfirm,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 사이즈 라벨 + 샘플 타일 (선택 가능)
// ═══════════════════════════════════════════════════════════════════════════

class _SampleTile extends StatelessWidget {
  final WidgetSize size;
  final String sizeLabel;
  final WidgetDisplayType style;
  final _InfoColor colorOpt;
  final String? photoPath;
  final bool selected;
  final VoidCallback onTap;

  const _SampleTile({
    required this.size,
    required this.sizeLabel,
    required this.style,
    required this.colorOpt,
    required this.photoPath,
    required this.selected,
    required this.onTap,
  });

  double get _aspect => switch (size) {
        WidgetSize.size2x1 => 2.0,
        WidgetSize.size2x2 => 1.0,
        WidgetSize.size4x2 => 2.0,
        WidgetSize.size4x4 => 1.0,
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          sizeLabel,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: AppTheme.gray900,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: selected ? AppTheme.tossBlue : Colors.transparent,
                width: 2,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: AppTheme.tossBlue.withValues(alpha: 0.22),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
            ),
            padding: const EdgeInsets.all(3),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: AspectRatio(
                aspectRatio: _aspect,
                child: _WidgetSample(
                  size: size,
                  style: style,
                  colorOpt: colorOpt,
                  photoPath: photoPath,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 실제 위젯 디자인을 재현하는 샘플 렌더러
// ═══════════════════════════════════════════════════════════════════════════

class _WidgetSample extends StatelessWidget {
  final WidgetSize size;
  final WidgetDisplayType style;
  final _InfoColor colorOpt;
  final String? photoPath;

  const _WidgetSample({
    required this.size,
    required this.style,
    required this.colorOpt,
    required this.photoPath,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        final h = c.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            _Background(
              style: style,
              photoPath: photoPath,
              infoBgColor: colorOpt.color,
            ),
            if (style == WidgetDisplayType.photoInfo)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: h * 0.35,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xD0000000)],
                    ),
                  ),
                ),
              ),
            if (style != WidgetDisplayType.photoOnly)
              _SampleContent(
                size: size,
                style: style,
                colorOpt: colorOpt,
                boxHeight: h,
              ),
          ],
        );
      },
    );
  }
}

/// 배경 — infoOnly: 사용자 선택 색상, photo*: 사진 or fallback.
class _Background extends StatelessWidget {
  final WidgetDisplayType style;
  final String? photoPath;
  final Color infoBgColor;

  const _Background({
    required this.style,
    required this.photoPath,
    required this.infoBgColor,
  });

  @override
  Widget build(BuildContext context) {
    if (style == WidgetDisplayType.infoOnly) {
      return ColoredBox(color: infoBgColor);
    }
    final path = photoPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 600,
      );
    }
    return Image.asset(
      'assets/images/sample_parking.jpg',
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const _ParkingGarageFallback(),
    );
  }
}

/// 저장된 사진이 없을 때 보여주는 주차장 분위기 멀티레이어 배경.
class _ParkingGarageFallback extends StatelessWidget {
  const _ParkingGarageFallback();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, c) {
        final h = c.maxHeight;
        final w = c.maxWidth;

        return Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF9AAABF),
                    Color(0xFF5C6E86),
                    Color(0xFF2C3A50),
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
            ),
            Positioned(
              top: -h * 0.4,
              left: 0,
              right: 0,
              height: h * 0.9,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.65,
                    colors: [Color(0x55FFFFFF), Color(0x00FFFFFF)],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: w * 0.13,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFFE8C572),
                      Color(0xFFC59A42),
                      Color(0xFF8B6B2A),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: w * 0.13,
              top: 0,
              bottom: 0,
              width: w * 0.04,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0x55000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: h * 0.16,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0x55000000)],
                  ),
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0.25, 0.15),
              child: Icon(
                Icons.directions_car_rounded,
                color: Colors.white.withValues(alpha: 0.22),
                size: h * 0.46,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 실제 위젯의 Info 영역 재현.
///
/// 사이즈별 정보 계층:
/// - 2x1: 층+구역 + 주차시간
/// - 2x2: 층+구역 + 주차시간 + 경과
/// - 4x2: 2x2 + 주소
/// - 4x4: 4x2와 동일
class _SampleContent extends StatelessWidget {
  final WidgetSize size;
  final WidgetDisplayType style;
  final _InfoColor colorOpt;
  final double boxHeight;

  const _SampleContent({
    required this.size,
    required this.style,
    required this.colorOpt,
    required this.boxHeight,
  });

  @override
  Widget build(BuildContext context) {
    final isInfo = style == WidgetDisplayType.infoOnly;
    // 색상 토큰
    final zoneColor = isInfo ? colorOpt.textColor : Colors.white;
    final timeColor = isInfo
        ? colorOpt.subTextColor
        : Colors.white.withValues(alpha: 0.90);

    // 치수 토큰 — zone 과 time 동일 사이즈 (네이티브 10sp:10sp 대응)
    final h = boxHeight;
    final pad = h * 0.07;
    final textFont = (h * 0.075).clamp(8.0, 13.0);
    final addrFont = (textFont * 0.9).clamp(6.0, 9.0);

    final textShadow = isInfo
        ? const <Shadow>[]
        : const <Shadow>[
            Shadow(
              color: Color(0x66000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ];

    // 사이즈별 텍스트 결정
    const sampleZone = '지하 1층 · 22구역';
    final sampleTime = switch (size) {
      WidgetSize.size2x1 => '4/18(금) 오후 12:15',
      WidgetSize.size2x2 => '4/18(금) 오후 12:15 · 주차 후 32분 경과',
      _ => '4월 18일(금) 오후 12:15 · 주차 후 32분 경과',
    };
    final showAddress =
        size == WidgetSize.size4x2 || size == WidgetSize.size4x4;

    // 공통 텍스트 스타일 (zone = time 동일)
    final zoneStyle = TextStyle(
      color: zoneColor,
      fontSize: textFont,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.2,
      shadows: textShadow,
    );
    final timeStyle = TextStyle(
      color: timeColor,
      fontSize: textFont,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      shadows: textShadow,
    );

    // 모든 사이즈 공통: 우측 하단 정렬
    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        mainAxisAlignment:
            size == WidgetSize.size2x1
                ? MainAxisAlignment.center
                : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            sampleZone,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: zoneStyle,
          ),
          SizedBox(height: h * 0.01),
          Text(
            sampleTime,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: timeStyle,
          ),
          if (showAddress) ...[
            SizedBox(height: h * 0.008),
            Text(
              '서울 강남구 테헤란로',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: timeColor,
                fontSize: addrFont,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
                shadows: textShadow,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 하단 그라디언트 CTA
// ═══════════════════════════════════════════════════════════════════════════

class _AddButton extends StatelessWidget {
  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  const _AddButton({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1.0 : 0.45,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            gradient: _ctaGradient,
            borderRadius: BorderRadius.circular(28),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppTheme.tossBlue.withValues(alpha: 0.30),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                )
              : const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, color: Colors.white, size: 22),
                    SizedBox(width: 4),
                    Text(
                      '위젯 추가하기',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
