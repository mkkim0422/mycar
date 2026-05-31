import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/navigation/route_observer.dart';
import '../../core/services/kakao_share_service.dart';
import '../../core/services/location_service.dart';
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

/// 주소 영역의 4-state.
///
/// - [resolved]   주소가 확보됨 → 도로명 주소 + 네이버 지도 버튼 표시
/// - [savingCoord] 좌표가 아직 저장되지 않음 (카메라가 BG 로 GPS 수거 중) →
///   "위치 저장 중..." 표시. 홈은 1초 간격 폴링으로 좌표 도착을 감지한다.
/// - [resolving]  좌표는 있으나 Kakao 역지오코딩 진행 중 → "위치 확인 중..."
/// - [none]       위 어느 상태도 아님 (저장된 좌표/주소 없음, 또는 모든 조회
///   실패) → "위치 정보 없음"
enum _AddressState { resolved, savingCoord, resolving, none }

/// ShellScreen이 GlobalKey를 통해 reload()를 호출할 수 있도록 public으로 선언.
///
/// RouteAware mixin 으로 위에 push 된 페이지(카메라/입력/설정/위젯설정)가 pop
/// 되어 홈이 다시 보일 때 [didPopNext] 가 호출되어 자동 reload 한다. 이는
/// _reloadHomeCallback 누락 케이스(_homeKey.currentState 가 일시적으로 null)
/// 에 대한 안전망.
class HomePageState extends State<HomePage> with RouteAware {
  final _repo = ParkingRepository();
  ParkingData? _data;
  bool _loading = true;

  /// data.address 가 비어있을 때 좌표로 역지오코딩한 결과.
  /// 카메라 시트에서 주소 UI 가 제거됐으므로 항상 null 로 저장된다 → 홈에 진입할
  /// 때 좌표를 이용해 늦게 조회한다. 결과는 화면 표시용으로만 사용 (DB 저장 X).
  String? _resolvedAddress;

  /// 좌표 → 주소 비동기 조회가 진행 중인지.
  bool _resolvingAddress = false;

  /// 좌표 도착 폴링 진행 중 플래그. 카메라에서 좌표 없이 저장된 직후 켜지며,
  /// 1초 간격으로 [ParkingRepository.get] 을 다시 읽어 BG 위치 업데이트가
  /// 같은 레코드를 갱신했는지 확인한다. 좌표가 도착하거나 60틱(약 60초) 후
  /// 자동 종료된다.
  bool _coordPolling = false;
  Timer? _coordPollTimer;

  /// 폴링 최대 60틱 — 카메라 BG Future 의 30초 GPS 타임아웃 + Kakao API +
  /// 디스크 쓰기 + 약간의 마진을 합한 안전값.
  static const _coordPollMaxTicks = 60;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 홈 라우트 자체에 옵저버를 구독해 위에 쌓인 페이지가 pop 될 때
    // didPopNext 가 호출되도록 한다.
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    // 카메라/입력/설정/위젯설정 등 위 페이지가 pop 되어 홈이 다시 보일 때 호출.
    // 사진 저장 후 _reloadHomeCallback 누락 케이스를 커버하는 안전망.
    debugPrint('[Home] didPopNext → 자동 reload');
    _load();
  }

  Future<void> _load() async {
    // Repository 가 손상된 SharedPreferences JSON 을 만나면 throw 할 수 있다.
    // 빈손(data=null) 으로 강등해 빈 상태 화면이 뜨도록 — 회색/검은 화면 방지.
    ParkingData? data;
    try {
      data = await _repo.get();
    } catch (e) {
      debugPrint('[HomePage] _repo.get 실패: $e');
      data = null;
    }
    if (!mounted) return;

    // 새 데이터 로드 시 이전 fallback / 폴링 상태를 모두 리셋.
    _coordPollTimer?.cancel();
    setState(() {
      _data = data;
      _loading = false;
      _resolvedAddress = null;
      _resolvingAddress = false;
      _coordPolling = false;
    });

    debugPrint('[Home] data.address: ${data?.address}');
    debugPrint('[Home] data.latitude: ${data?.latitude}');
    debugPrint('[Home] data.longitude: ${data?.longitude}');

    if (data == null) {
      debugPrint('[Home] 데이터 없음 — 폴링 스킵');
      return;
    }

    // 좌표가 아직 저장되지 않은 신규 레코드 → 카메라 BG Future 가 곧
    // updateLocation 으로 좌표를 채울 것이다. 1초 간격으로 폴링.
    if (data.latitude == null || data.longitude == null) {
      debugPrint('[Home] 좌표 없음 — 폴링 시작');
      _startCoordPolling();
      return;
    }

    // 좌표 있음 + 주소 비었음 → Kakao 역지오코딩.
    if (data.address == null || data.address!.isEmpty) {
      debugPrint('[Home] 주소조회 시작');
      _resolveAddressInBackground(data.latitude!, data.longitude!);
    } else {
      debugPrint('[Home] 주소·좌표 모두 있음 — 추가 조회 스킵');
    }
  }

  /// 1초 간격으로 [ParkingRepository.get] 을 재조회해 BG 위치 업데이트가
  /// 같은 레코드를 갱신했는지 확인한다.
  ///
  /// ## 종료 조건
  /// - 좌표가 도착함 → 타이머 취소, _data 갱신, 필요 시 주소 조회 시작.
  /// - 60틱(약 60초) 도달 → 타이머 취소, "위치 정보 없음" 상태로 정착.
  /// - 위젯 unmount → 타이머 취소.
  void _startCoordPolling() {
    _coordPollTimer?.cancel();
    var ticks = 0;
    setState(() => _coordPolling = true);
    _coordPollTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      ticks++;
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (ticks > _coordPollMaxTicks) {
        timer.cancel();
        debugPrint('[Home] 좌표 폴링 타임아웃 — 종료');
        if (mounted) setState(() => _coordPolling = false);
        return;
      }

      ParkingData? fresh;
      try {
        fresh = await _repo.get();
      } catch (_) {
        fresh = null;
      }
      if (!mounted) {
        timer.cancel();
        return;
      }

      // 같은 timestamp 의 레코드에 좌표가 채워졌으면 폴링 종료.
      if (fresh != null &&
          fresh.latitude != null &&
          fresh.longitude != null &&
          _data?.timestamp == fresh.timestamp) {
        timer.cancel();
        debugPrint(
          '[Home] 좌표 폴링 hit: lat=${fresh.latitude}, '
          'lng=${fresh.longitude}, addr=${fresh.address}',
        );
        setState(() {
          _data = fresh;
          _coordPolling = false;
        });
        // BG 가 주소까지 채웠다면 추가 조회 불필요. 비었으면 Kakao 한 번 더 호출.
        if (fresh.address == null || fresh.address!.isEmpty) {
          _resolveAddressInBackground(fresh.latitude!, fresh.longitude!);
        }
      }
    });
  }

  /// 좌표를 Kakao Local API 로 역지오코딩하여 [_resolvedAddress] 에 채운다.
  /// 실패해도 앱은 정상 동작 — UI 는 "위치 정보 없음" 상태로 표시된다.
  Future<void> _resolveAddressInBackground(double lat, double lng) async {
    if (mounted) {
      setState(() => _resolvingAddress = true);
      debugPrint('[Home] addressLoading: true');
    }
    // LocationService 내부에서 이미 throw 를 swallow 하지만 (네트워크 패키지가
    // 던질 수 있는 예외 종류가 다양해) 호출 측에서도 한 번 더 가드 — 어떤 실패도
    // 로딩 스피너를 영원히 남기는 회귀로 이어지지 않게 한다.
    String? addr;
    try {
      addr = await LocationService.reverseGeocode(lat, lng);
    } catch (e) {
      debugPrint('[HomePage] reverseGeocode 예외: $e');
      addr = null;
    }
    if (!mounted) return;
    setState(() {
      _resolvingAddress = false;
      _resolvedAddress = addr; // null 이면 실패 — UI 가 "위치 정보 없음" 으로 처리
    });
    debugPrint('[Home] resolvedAddress: $addr');
    debugPrint('[Home] addressLoading: false');
  }

  /// 카메라에서 돌아온 후 데이터 새로고침을 위해 외부에서 호출 가능.
  Future<void> reload() => _load();

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _coordPollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 4-state 주소 영역.
    //   1) 저장된 data.address 또는 늦게 조회한 _resolvedAddress 가 있으면 resolved.
    //   2) 좌표가 아직 없는 상태에서 폴링 진행 중이면 savingCoord.
    //   3) 좌표는 있으나 Kakao 응답 대기 중이면 resolving.
    //   4) 그 외 (모두 실패 또는 데이터 없음) 는 none.
    String? displayAddress;
    _AddressState addressState = _AddressState.none;

    final dataAddr = _data?.address;
    if (dataAddr != null && dataAddr.isNotEmpty) {
      displayAddress = dataAddr;
      addressState = _AddressState.resolved;
    } else if (_resolvedAddress != null && _resolvedAddress!.isNotEmpty) {
      displayAddress = _resolvedAddress;
      addressState = _AddressState.resolved;
    } else if (_data?.latitude == null && _coordPolling) {
      addressState = _AddressState.savingCoord;
    } else if (_data?.latitude != null && _resolvingAddress) {
      addressState = _AddressState.resolving;
    }

    return Scaffold(
      backgroundColor: AppTheme.gray100,
      appBar: _buildAppBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.tossBlue))
          : _data == null
              ? _EmptyBody(onRegisterTap: widget.onRegisterTap)
              : _DataBody(
                data: _data!,
                displayAddress: displayAddress,
                addressState: addressState,
                onRegisterTap: widget.onRegisterTap,
                onShareTap: () => KakaoShareService.share(context, _data!),
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
      title: const Text('주차기억'),
      // 설정 진입점 — 하단 네비게이션 바 제거 후 우측 상단 톱니바퀴로 이동.
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_rounded),
          color: AppTheme.gray900,
          tooltip: '설정',
          onPressed: () => Navigator.of(context).pushNamed('/settings'),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

// ── 데이터 있음 ──────────────────────────────────────────────────────────────

class _DataBody extends StatelessWidget {
  final ParkingData data;

  /// 화면에 표시할 주소. [addressState] 가 [_AddressState.resolved] 일 때만 의미 있다.
  final String? displayAddress;

  /// 주소 영역의 현재 상태. 라벨/아이콘/네이버 지도 버튼 노출 여부를 결정한다.
  final _AddressState addressState;

  final VoidCallback onRegisterTap;
  final VoidCallback? onShareTap;

  const _DataBody({
    required this.data,
    required this.displayAddress,
    required this.addressState,
    required this.onRegisterTap,
    this.onShareTap,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxH = constraints.maxHeight;
          // 사진 카드: 고정 비율 대신 화면 높이에 비례(반응형).
          // 가로 모드처럼 세로가 짧아지면 자동 축소되되, 너무 작아지지
          // 않도록 클램프.
          final imageHeight = (maxH * 0.42).clamp(150.0, 420.0);

          // 세로 공간이 충분하면 기존처럼 버튼이 하단에 고정(Spacer),
          // 부족하면(가로 모드 등) overflow 대신 스크롤되도록:
          //   SingleChildScrollView + ConstrainedBox(minHeight=뷰포트)
          //   + IntrinsicHeight 조합 (Expanded/Spacer 가 스크롤 안에서도
          //   안전하게 동작하는 표준 패턴).
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: maxH),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spacingPage),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),

                      // ── 사진 카드 (반응형 높이) ──────────────────────
                      SizedBox(
                        height: imageHeight,
                        child: _ParkingImageCard(
                          photoPath: data.photoPath,
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

                      // ── 주차 구역 텍스트 + 공유 버튼 ───────────────
                      // 사진 위 오버레이가 아닌 텍스트 라인 우측에 배치해
                      // 사진 탭(전체화면)과 충돌하지 않게 한다.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: _ZoneDisplay(data: data)),
                          if (onShareTap != null) ...[
                            const SizedBox(width: 8),
                            _ShareIconButton(onTap: onShareTap!),
                          ],
                        ],
                      ),

                      const SizedBox(height: 10),

                      // ── 주차 시간 ──────────────────────────────────
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

                      // ── 경과 시간 ──────────────────────────────────
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

                      // ── 주차 지점 주소 (4-state) ───────────────────
                      //    저장 시점엔 좌표·주소 모두 null. 카메라 BG
                      //    Future 가 곧 좌표·주소를 채우면 폴링이 감지해
                      //    _data 를 갱신한다.
                      //    1) resolved    → 주소 + 네이버 지도 버튼
                      //    2) savingCoord → "위치 저장 중..."
                      //    3) resolving   → "위치 확인 중..."
                      //    4) none        → "위치 정보 없음"
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _AddressLine(
                          address: displayAddress,
                          state: addressState,
                        ),
                      ),

                      // ── 네이버 지도 (주소 확보 시에만 노출) ─────────
                      if (addressState == _AddressState.resolved &&
                          data.latitude != null &&
                          data.longitude != null)
                        _NaverMapButton(
                          latitude: data.latitude!,
                          longitude: data.longitude!,
                          address: data.address ?? displayAddress,
                        ),

                      const SizedBox(height: 16),

                      // 세로 여유가 있을 때만 버튼을 바닥으로 밀어내는
                      // 신축 공간(가로 모드에선 0 으로 접혀 스크롤됨).
                      const Spacer(),

                      // ── 주차 등록 버튼 ─────────────────────────────
                      _PrimaryButton(
                        label: '+ 신규등록',
                        onTap: onRegisterTap,
                      ),

                      // AdMob 정책: 주요 액션 버튼과 광고 배너 사이 충분한
                      // 여백 확보 (실수 클릭 방지). 48dp 표준 터치 타겟 이상.
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
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

// ── 주소 라인 (3-state) ──────────────────────────────────────────────────────

/// 주차 지점 주소를 표시하는 한 줄 컴포넌트.
///
/// [state] 에 따라 다음 4가지 상태로 자동 전환된다:
/// - **resolved**    : 파란 핀 + [address] 도로명/지번
/// - **savingCoord** : 탐색 아이콘 + "위치 저장 중..." (좌표 도착 대기)
/// - **resolving**   : 탐색 아이콘 + "위치 확인 중..." (Kakao 응답 대기)
/// - **none**        : 회색 핀-OFF + "위치 정보 없음"
class _AddressLine extends StatelessWidget {
  final String? address;
  final _AddressState state;

  const _AddressLine({required this.address, required this.state});

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color iconColor;
    final String text;
    final Color textColor;
    final FontWeight fontWeight;

    switch (state) {
      case _AddressState.resolved:
        icon = Icons.place_rounded;
        iconColor = AppTheme.tossBlue;
        text = address ?? '';
        textColor = const Color(0xFF333D4B);
        fontWeight = FontWeight.w600;
      case _AddressState.savingCoord:
        icon = Icons.location_searching_rounded;
        iconColor = AppTheme.gray500;
        text = '위치 저장 중...';
        textColor = AppTheme.gray500;
        fontWeight = FontWeight.w500;
      case _AddressState.resolving:
        icon = Icons.location_searching_rounded;
        iconColor = AppTheme.gray500;
        text = '위치 확인 중...';
        textColor = AppTheme.gray500;
        fontWeight = FontWeight.w500;
      case _AddressState.none:
        icon = Icons.location_off_rounded;
        iconColor = AppTheme.gray500;
        text = '위치 정보 없음';
        textColor = AppTheme.gray500;
        fontWeight = FontWeight.w500;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E8EB), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: fontWeight,
                color: textColor,
                height: 1.4,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 세로가 짧으면(가로 모드) overflow 대신 스크롤. 충분하면
          // 기존처럼 Spacer 비율로 중앙 정렬 + 버튼 하단.
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.spacingPage),
                  child: Column(
                    children: [
                      const Spacer(flex: 3),

                      // 빈 상태 일러스트 영역
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: AppTheme.gray200,
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusImage),
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

                      _PrimaryButton(
                          label: '+ 신규등록', onTap: onRegisterTap),

                      // AdMob 정책: 광고 배너와 액션 버튼 사이 48dp 여백.
                      const SizedBox(height: 48),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── 서브 위젯 ─────────────────────────────────────────────────────────────────

/// Full-bleed 주차 사진 카드.
/// 사진 경로가 없으면 그라디언트 플레이스홀더를 표시한다.
/// [onPhotoTap]이 제공되면 사진 본문을 탭했을 때 호출된다 (전체화면 뷰어용).
class _ParkingImageCard extends StatelessWidget {
  final String? photoPath;
  final VoidCallback? onPhotoTap;

  const _ParkingImageCard({
    this.photoPath,
    this.onPhotoTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = photoPath != null && File(photoPath!).existsSync();

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusImage),
      // SizedBox.expand 로 자식을 부모(이미지 카드 SizedBox) 영역 전체로 확장.
      // 없으면 Image 가 본인 intrinsic 비율로 축소되어 카드가 작게 표시됨.
      child: SizedBox.expand(
        // 사진이 있을 때만 탭 이벤트 수신 (placeholder 는 의미 없음).
        child: GestureDetector(
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
      ),
    );
  }
}

/// 구역 텍스트 라인 우측에 들어가는 미니멀 공유 버튼.
/// 사진 위에 오버레이하지 않아 사진 탭(전체화면 뷰어)과 충돌하지 않는다.
class _ShareIconButton extends StatelessWidget {
  final VoidCallback onTap;

  const _ShareIconButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          color: AppTheme.gray100,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.ios_share_rounded,
          color: AppTheme.gray900,
          size: 20,
        ),
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
