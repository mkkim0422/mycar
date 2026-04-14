import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/kakao_share_service.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/parking_data.dart';
import '../../data/repositories/parking_repository.dart';

/// 홈 화면.
///
/// ## 레이아웃 (스크린샷 3번 기준)
///
/// ### 데이터 있을 때
/// ```
/// AppBar  [내차어디]  [내 차량 ▾]
/// ─────────────────────────────────
/// [Full-bleed 사진 카드 r=28]
/// [구역 텍스트  34sp w900      ]
/// [타임스탬프   16sp #8B95A1   ]
/// Spacer
/// [+ 주차 등록 버튼 h=60 r=28 ]
/// ```
///
/// ### 데이터 없을 때 (스크린샷 1번)
/// ```
/// AppBar
/// ─────────────────────────────────
/// (Spacer)
/// [차량 아이콘  80dp            ]
/// [아직 저장된 기록이 없어요      ]
/// [안내 문구                     ]
/// (Spacer)
/// [+ 주차 등록 버튼              ]
/// ```
class HomePage extends StatefulWidget {
  /// 카메라 화면 열기 콜백.
  /// ShellScreen → Navigator.push('/camera') 처리.
  final VoidCallback onRegisterTap;

  const HomePage({super.key, required this.onRegisterTap});

  @override
  State<HomePage> createState() => HomePageState();
}

/// ShellScreen이 GlobalKey를 통해 reload()를 호출할 수 있도록 public으로 선언.
class HomePageState extends State<HomePage> {
  final _repo = ParkingRepository();
  ParkingData? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await _repo.get();
    if (mounted) setState(() { _data = data; _loading = false; });
  }

  /// 카메라에서 돌아온 후 데이터 새로고침을 위해 외부에서 호출 가능.
  Future<void> reload() => _load();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      appBar: _buildAppBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.tossBlue))
          : _data == null
              ? _EmptyBody(onRegisterTap: widget.onRegisterTap)
              : _DataBody(
                data: _data!,
                onRegisterTap: widget.onRegisterTap,
                onShareTap: () =>
                    KakaoShareService.share(context, _data!),
              ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: AppTheme.gray100,
      title: const Text('내차어디'),
      // 우측: 차량 선택(향후 확장용 플레이스홀더)
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Row(
            children: [
              const Text(
                '내 차량',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.gray900,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.keyboard_arrow_down_rounded,
                  size: 20, color: AppTheme.gray500),
            ],
          ),
        ),
      ],
    );
  }
}

// ── 데이터 있음 ──────────────────────────────────────────────────────────────

class _DataBody extends StatelessWidget {
  final ParkingData data;
  final VoidCallback onRegisterTap;
  final VoidCallback? onShareTap;

  const _DataBody({
    required this.data,
    required this.onRegisterTap,
    this.onShareTap,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingPage),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),

            // ── Full-bleed 사진 카드 ──────────────────────────────────────
            Expanded(
              flex: 58, // 화면 높이의 약 58% 차지
              child: _ParkingImageCard(
                photoPath: data.photoPath,
                onShareTap: onShareTap,
              ),
            ),

            const SizedBox(height: 20),

            // ── 주차 구역 텍스트 (34sp / w900) ───────────────────────────
            _ZoneDisplay(data: data),

            const SizedBox(height: 6),

            // ── 주차 시간 (16sp / #8B95A1) ────────────────────────────────
            Text(
              _formatTimestamp(data.timestamp),
              style: const TextStyle(
                fontSize: AppTheme.fontBody1,
                fontWeight: FontWeight.w500,
                color: AppTheme.gray500,
                letterSpacing: -0.2,
              ),
            ),

            const Spacer(),

            // ── 주차 등록 버튼 ────────────────────────────────────────────
            _PrimaryButton(
              label: '+ 주차 등록',
              onTap: onRegisterTap,
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final hour = dt.hour;
    final ampm = hour < 12 ? '오전' : '오후';
    final hour12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}년 ${dt.month}월 ${dt.day}일  $ampm $hour12:$min 주차';
  }
}

// ── 빈 상태 ──────────────────────────────────────────────────────────────────

class _EmptyBody extends StatelessWidget {
  final VoidCallback onRegisterTap;

  const _EmptyBody({required this.onRegisterTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingPage),
        child: Column(
          children: [
            const Spacer(flex: 3),

            // 빈 상태 일러스트 영역
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: AppTheme.gray200,
                borderRadius: BorderRadius.circular(AppTheme.radiusImage),
              ),
              child: const Icon(
                Icons.local_parking_rounded,
                size: 56,
                color: AppTheme.gray500,
              ),
            ),

            const SizedBox(height: 24),

            // 메인 문구
            const Text(
              '아직 저장된 기록이 없어요',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppTheme.gray900,
                letterSpacing: -0.4,
              ),
            ),

            const SizedBox(height: 10),

            // 보조 문구
            const Text(
              '주차 후 카메라 버튼을 눌러\n구역 번호를 촬영해 보세요.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontBody1,
                fontWeight: FontWeight.w400,
                color: AppTheme.gray500,
                height: 1.55,
                letterSpacing: -0.2,
              ),
            ),

            const Spacer(flex: 4),

            _PrimaryButton(label: '+ 주차 등록', onTap: onRegisterTap),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ── 서브 위젯 ─────────────────────────────────────────────────────────────────

/// Full-bleed 주차 사진 카드.
/// 사진 경로가 없으면 그라디언트 플레이스홀더를 표시한다.
/// [onShareTap]이 제공되면 우상단에 공유 버튼을 오버레이한다.
class _ParkingImageCard extends StatelessWidget {
  final String? photoPath;
  final VoidCallback? onShareTap;

  const _ParkingImageCard({this.photoPath, this.onShareTap});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusImage),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 배경 이미지 or 플레이스홀더 ──────────────────────────────
          photoPath != null && File(photoPath!).existsSync()
              ? Image.file(
                  File(photoPath!),
                  fit: BoxFit.cover,
                  // 최대 디코딩 너비 제한 → 대용량 사진의 메모리 스파이크 방지
                  cacheWidth: 1200,
                )
              : _PlaceholderImage(),

          // ── 우상단 공유 버튼 ─────────────────────────────────────────
          if (onShareTap != null)
            Positioned(
              top: 12,
              right: 12,
              child: GestureDetector(
                onTap: onShareTap,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.80),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.ios_share_rounded,
                    color: AppTheme.gray900,
                    size: 20,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlaceholderImage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFDCE6FF), Color(0xFFB8CEFF)],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.image_outlined,
          size: 56,
          color: AppTheme.tossBlue,
        ),
      ),
    );
  }
}

/// 주차 구역 / 층수 텍스트 표시.
/// floor == zone이면 하나만 표시; 다르면 zone(대형) + floor(소형)로 분리.
class _ZoneDisplay extends StatelessWidget {
  final ParkingData data;

  const _ZoneDisplay({required this.data});

  @override
  Widget build(BuildContext context) {
    final showFloorSeparately = data.floor != '-' && data.floor != data.zone;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 구역: 34sp / w900
        Text(
          data.zone,
          style: const TextStyle(
            fontSize: AppTheme.fontDisplay,
            fontWeight: FontWeight.w900,
            color: AppTheme.gray900,
            letterSpacing: -1.2,
            height: 1.15,
          ),
        ),
        if (showFloorSeparately) ...[
          const SizedBox(height: 2),
          // 층수 보조 뱃지
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.tossBlue.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppTheme.radiusChip),
            ),
            child: Text(
              data.floor,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.tossBlue,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 하단 주요 CTA 버튼.
/// 높이 60dp / 반경 28dp / 파란색.
class _PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PrimaryButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: AppTheme.btnPrimary,
        decoration: BoxDecoration(
          color: AppTheme.tossBlue,
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: AppTheme.fontBody1,
            fontWeight: FontWeight.w700,
            color: AppTheme.white,
            letterSpacing: -0.2,
          ),
        ),
      ),
    );
  }
}
