import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/services/kakao_share_service.dart';
import '../../core/services/map_service.dart';
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
                // 카카오 앱키가 플레이스홀더 상태면 공유 버튼 자체를 감춰
                // "wrong appKey … format" 에러가 뜨지 않게 한다.
                onShareTap: AppConfig.isKakaoConfigured
                    ? () => KakaoShareService.share(context, _data!)
                    : null,
              ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: AppTheme.gray100,
      // 내차위치는 Shell 의 루트 탭이므로 어떤 Navigator 스택 상태에서도
      // 뒤로가기 아이콘이 뜨면 안 된다. automaticallyImplyLeading 을 끄면
      // widget-setup / camera 등 상위 페이지에서 pop 해 돌아온 직후에도
      // canPop() 잔재로 인한 back 아이콘 노출이 원천 차단된다.
      automaticallyImplyLeading: false,
      title: const Text('내차어디'),
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
            const SizedBox(height: 16),

            // ── 사진 카드 (화면의 ~38%) ──────────────────────────────────
            Expanded(
              flex: 38,
              child: _ParkingImageCard(
                photoPath: data.photoPath,
                onShareTap: onShareTap,
                onPhotoTap: () {
                  final path = data.photoPath;
                  if (path == null || path.isEmpty) return;
                  if (!File(path).existsSync()) return;
                  Navigator.of(context).push(
                    _FullscreenPhotoRoute(path: path),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // ── 주차 구역 텍스트 ─────────────────────────────────────────
            _ZoneDisplay(data: data),

            const SizedBox(height: 10),

            // ── 주차 시간 ────────────────────────────────────────────────
            Text(
              _formatTimestamp(data.timestamp),
              style: const TextStyle(
                fontSize: AppTheme.fontBody1,
                fontWeight: FontWeight.w500,
                color: AppTheme.gray500,
                height: 1.6,
                letterSpacing: -0.2,
              ),
            ),

            const SizedBox(height: 6),

            // ── 경과 시간 ─────────────────────────────────────────────
            Text(
              _formatElapsed(data.timestamp),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.tossBlue,
                height: 1.5,
                letterSpacing: -0.2,
              ),
            ),

            const SizedBox(height: 12),

            // ── 주차 지점 주소 (역지오코딩 결과) ─────────────────────────
            //    카메라 결과 화면과 동일한 스타일로 표시한다.
            if (data.address != null && data.address!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7F9FC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: const Color(0xFFE5E8EB), width: 0.5),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.place_rounded,
                          size: 16, color: AppTheme.tossBlue),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          data.address!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF333D4B),
                            height: 1.4,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── 네이버 지도 바로가기 (좌표가 있을 때만 표시) ─────────────
            if (data.latitude != null && data.longitude != null)
              _NaverMapButton(
                latitude: data.latitude!,
                longitude: data.longitude!,
                address: data.address,
              ),

            const Spacer(),

            // ── 주차 등록 버튼 ────────────────────────────────────────────
            _PrimaryButton(
              label: '+ 신규등록',
              onTap: onRegisterTap,
            ),

            const SizedBox(height: 16),
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

  /// 경과 시간 표기.
  /// - 3분 미만    : "방금전"
  /// - 3~59분      : "주차 후 #분 경과"
  /// - 60분~23시간 : "주차 후 #시간 #분 경과"
  /// - 24시간 이상 : "주차 후 #일 #시간 #분 경과" (시/분이 0이면 생략)
  String _formatElapsed(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    final totalMin = diff.inMinutes;
    if (totalMin < 3) return '방금전';

    final days = diff.inDays;
    final hours = (totalMin ~/ 60) % 24;
    final mins = totalMin % 60;

    // 24시간 이상 경과 — "일" 단위로 스위치
    if (days >= 1) {
      if (hours == 0 && mins == 0) return '주차 후 ${days}일 경과';
      if (hours == 0) return '주차 후 ${days}일 ${mins}분 경과';
      if (mins == 0) return '주차 후 ${days}일 ${hours}시간 경과';
      return '주차 후 ${days}일 ${hours}시간 ${mins}분 경과';
    }

    // 24시간 미만
    if (hours < 1) return '주차 후 ${totalMin}분 경과';
    if (mins == 0) return '주차 후 ${hours}시간 경과';
    return '주차 후 ${hours}시간 ${mins}분 경과';
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

            _PrimaryButton(label: '+ 신규등록', onTap: onRegisterTap),

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
/// [onPhotoTap]이 제공되면 사진 본문을 탭했을 때 호출된다 (전체화면 뷰어용).
class _ParkingImageCard extends StatelessWidget {
  final String? photoPath;
  final VoidCallback? onShareTap;
  final VoidCallback? onPhotoTap;

  const _ParkingImageCard({
    this.photoPath,
    this.onShareTap,
    this.onPhotoTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = photoPath != null && File(photoPath!).existsSync();

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusImage),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 배경 이미지 or 플레이스홀더 ──────────────────────────────
          // 사진이 있을 때만 탭 이벤트 수신 (placeholder 는 의미 없음).
          GestureDetector(
            onTap: hasImage ? onPhotoTap : null,
            child: hasImage
                ? Image.file(
                    File(photoPath!),
                    fit: BoxFit.cover,
                    // 대용량 사진의 메모리 스파이크 방지
                    cacheWidth: 1200,
                  )
                : _PlaceholderImage(),
          ),

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

/// 주차 층수 / 구역 텍스트 표시 (Toss 스타일 · 동일 레벨).
///
/// 층과 구역을 같은 크기·굵기로 나란히 배치하고, 색으로만 강약을 준다.
/// - 층(floor) : gray900  · 메인 정보
/// - 구역(zone): tossBlue · 식별값 강조
///
/// 둘 중 하나가 비어 있거나 "-" 면 해당 항목은 렌더하지 않는다.
class _ZoneDisplay extends StatelessWidget {
  final ParkingData data;

  const _ZoneDisplay({required this.data});

  @override
  Widget build(BuildContext context) {
    final showFloor = data.floor.isNotEmpty && data.floor != '-';
    final showZone = data.zone.isNotEmpty && data.zone != '-';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (showFloor)
          Flexible(
            child: Text(
              data.floor,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: AppTheme.gray900,
                letterSpacing: -0.9,
                height: 1.15,
              ),
            ),
          ),
        if (showFloor && showZone) const SizedBox(width: 12),
        if (showZone)
          Flexible(
            child: Text(
              _formatZone(data.zone),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: AppTheme.tossBlue,
                letterSpacing: -0.9,
                height: 1.15,
              ),
            ),
          ),
      ],
    );
  }

  /// 구역 표기에 "구역" 접미사를 덧붙인다.
  /// 이미 "구역"으로 끝나는 입력(예: "3구역")은 그대로 둬 중복을 방지.
  static String _formatZone(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == '-') return trimmed;
    if (trimmed.endsWith('구역')) return trimmed;
    return '$trimmed구역';
  }
}

/// 사진 카드 바로 아래에 붙는 슬림 보조 CTA — 네이버 지도로 점프.
/// 높이 44dp · 연한 파란 틴트 배경 · Toss Blue 텍스트로 프리미엄 톤 유지.
class _NaverMapButton extends StatelessWidget {
  final double latitude;
  final double longitude;
  final String? address;

  const _NaverMapButton({
    required this.latitude,
    required this.longitude,
    this.address,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => MapService.openLocation(
        latitude: latitude,
        longitude: longitude,
        address: address,
      ),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: AppTheme.tossBlue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map_rounded, size: 16, color: AppTheme.tossBlue),
            SizedBox(width: 6),
            Text(
              '네이버 지도로 위치 보기',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppTheme.tossBlue,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
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

// ── Fullscreen Photo Viewer ─────────────────────────────────────────────────

/// 전체 화면 사진 뷰어 라우트. 페이드 인/아웃 + 검정 배경.
/// InteractiveViewer 로 핀치-줌/패닝 지원. 좌상단 X 탭 시 닫힘.
class _FullscreenPhotoRoute extends PageRouteBuilder<void> {
  _FullscreenPhotoRoute({required String path})
      : super(
          opaque: false,
          barrierColor: Colors.black,
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 150),
          pageBuilder: (_, __, ___) => _FullscreenPhotoView(path: path),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: anim,
            child: child,
          ),
        );
}

class _FullscreenPhotoView extends StatelessWidget {
  final String path;

  const _FullscreenPhotoView({required this.path});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 배경 탭으로도 닫힘
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
            child: InteractiveViewer(
              maxScale: 4,
              child: Center(
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
          // 좌상단 X 닫기 버튼
          Positioned(
            top: MediaQuery.of(context).padding.top + 4,
            left: 4,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
