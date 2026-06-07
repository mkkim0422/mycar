import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/services/billing_service.dart';
import '../../core/theme/app_theme.dart';
import 'parking_history_page.dart';
import 'policy_page.dart';

/// 블루투스 자동 감지 토글 저장 키.
///
/// 이 값이 false 면 Kotlin 쪽 [BluetoothDisconnectReceiver] 와
/// [MotionDetectionService] 가 조기 return 해 알림을 발송하지 않는다.
/// 네이티브 키는 `flutter.bt_auto_enabled` (shared_preferences 규칙).
const _kBtAutoEnabledKey = 'bt_auto_enabled';

/// 네이티브 공용 MethodChannel (페어링 기기 조회 / SecurePrefs 접근).
///
/// 수동 태깅된 차량 BT MAC 은 `shared_preferences` 평문 대신
/// AndroidKeyStore 마스터 키로 암호화된 네이티브 저장소
/// ([SecurePrefsHelper]) 로 이동했다. Dart 에서는 이 채널을 통해서만 접근한다.
const _nativeChannel = MethodChannel('com.snappark/widget');

/// 설정 화면.
///
/// ## 섹션 구성
/// 1. 주차 기록  — 저장된 기록 초기화
/// 2. 자동화     — 블루투스 자동 감지 토글
/// 3. 앱         — 버전 정보 / 알림 설정 안내
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _btAutoEnabled = true;

  /// 현재 '내 차'로 태깅된 기기 정보. null 이면 미등록 상태.
  _TaggedCar? _taggedCar;

  /// 자동 학습으로 확정된 '내 차' 정보. null 이면 아직 학습 전(학습 중).
  _TaggedCar? _learnedCar;

  @override
  void initState() {
    super.initState();
    _loadTaggedCar();
    _loadLearnedCar();
    _loadBtAutoEnabled();
    // 상품 조회 / 영속 플래그 로드 (main 에서 이미 호출 — 멱등).
    BillingService.instance.init();
  }

  /// BT 자동 감지 토글 상태를 영속 저장소에서 로드한다. 기본값 true.
  Future<void> _loadBtAutoEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_kBtAutoEnabledKey) ?? true;
    if (mounted && v != _btAutoEnabled) setState(() => _btAutoEnabled = v);
  }

  /// 토글 변경 → 영속 저장 → 네이티브 Receiver 가 즉시 반영.
  Future<void> _setBtAutoEnabled(bool enabled) async {
    setState(() => _btAutoEnabled = enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBtAutoEnabledKey, enabled);
  }

  /// 저장된 태깅 기기 MAC/이름을 네이티브 암호화 저장소에서 로드한다.
  Future<void> _loadTaggedCar() async {
    Map<String, String>? info;
    try {
      final raw = await _nativeChannel.invokeMethod<Map<dynamic, dynamic>>(
        'secureGetManualCar',
      );
      info = raw?.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      info = null;
    }

    if (!mounted) return;
    setState(() {
      _taggedCar = (info != null && (info['mac']?.isNotEmpty ?? false))
          ? _TaggedCar(
              name: info['name'] ?? '(이름 없음)',
              address: info['mac']!,
            )
          : null;
    });
  }

  /// 자동 학습된 '내 차' 정보를 네이티브에서 로드한다.
  Future<void> _loadLearnedCar() async {
    Map<String, String>? info;
    try {
      final raw = await _nativeChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getLearnedCar',
      );
      info = raw?.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      info = null;
    }
    if (!mounted) return;
    setState(() {
      _learnedCar = (info != null && (info['mac']?.isNotEmpty ?? false))
          ? _TaggedCar(name: info['name'] ?? '내 차', address: info['mac']!)
          : null;
    });
  }

  /// 학습 결과를 초기화한다. 잘못 학습됐거나 차를 바꿨을 때 사용.
  Future<void> _resetCarLearning() async {
    try {
      await _nativeChannel.invokeMethod<void>('resetCarLearning');
    } catch (_) {}
    if (!mounted) return;
    // 네이티브 상태를 다시 읽어 UI 를 일관되게 갱신.
    await _loadLearnedCar();
    await _loadTaggedCar();
    if (!mounted) return;
    _showSnackBar('학습을 초기화했습니다. 다음 주행부터 다시 학습합니다.');
  }

  /// 페어링된 BT 기기 목록 바텀시트를 열고, 사용자가 선택한 기기를 태깅한다.
  ///
  /// ※ 새로운 BT 연결/스캔을 시도하지 않는다. 이미 OS 에 페어링(Bonded)된
  ///    기기 목록만 조회하여 '차량으로 간주할' 기기를 명시적으로 태깅한다.
  Future<void> _openManualCarPicker() async {
    // 네이티브에서 bondedDevices 만 조회 (신규 연결 시도 없음)
    List<Map<String, String>> devices;
    try {
      final raw = await _nativeChannel.invokeMethod<List<dynamic>>(
        'getPairedDevices',
      );
      devices = (raw ?? [])
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v.toString())))
          .toList();
    } catch (_) {
      devices = [];
    }

    if (!mounted) return;

    final selected = await showModalBottomSheet<Map<String, String>?>(
      context: context,
      backgroundColor: AppTheme.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (_) => _PairedDevicePickerSheet(
        devices: devices,
        currentAddress: _taggedCar?.address,
      ),
    );

    if (selected == null || !mounted) return;

    if (selected.isEmpty) {
      // 태깅 해제 — 암호화 저장소의 키도 함께 제거된다.
      try {
        await _nativeChannel.invokeMethod<void>('secureClearManualCar');
      } catch (_) {}
      if (!mounted) return;
      setState(() => _taggedCar = null);
      _showSnackBar('내 차 태깅이 해제되었습니다.');
      return;
    }

    final mac = selected['address'] ?? '';
    final name = selected['name'] ?? '(이름 없음)';
    try {
      await _nativeChannel.invokeMethod<void>(
        'secureSetManualCar', {'mac': mac, 'name': name},
      );
    } catch (_) {
      if (!mounted) return;
      _showSnackBar('암호화 저장소 저장에 실패했습니다.');
      return;
    }

    if (!mounted) return;
    setState(() => _taggedCar = _TaggedCar(name: name, address: mac));
    _showSnackBar('"$name" 을(를) 내 차로 등록했습니다.');
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: const TextStyle(fontWeight: FontWeight.w500)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.gray900,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusChip)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
    );
  }

  // ── 의견 · 공유 ────────────────────────────────────────────────────────

  void _openFeedbackSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _FeedbackSheet(),
    );
  }

  /// 별점 주기 — 추후 출시될 Play 스토어 페이지로 연결.
  Future<void> _openStoreForRating() async {
    final uri = Uri.parse(AppConfig.appLandingUrl);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _showSnackBar('스토어를 열 수 없습니다.');
    } catch (_) {
      if (mounted) _showSnackBar('스토어를 열 수 없습니다.');
    }
  }

  /// 친구에게 추천 — OS 공유 시트(카톡/메시지/기타 앱).
  Future<void> _shareApp() async {
    await SharePlus.instance.share(
      ShareParams(
        text: "주차한 위치를 사진과 구역으로 자동 기록하는 '주차기억'.\n"
            '${AppConfig.appLandingUrl}',
      ),
    );
  }

  // ── 결제(광고 제거) ────────────────────────────────────────────────────

  Widget _buildRemoveAdsRow() {
    final billing = BillingService.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: billing.adRemoved,
      builder: (_, removed, __) {
        if (removed) {
          return _ActionRow(
            icon: Icons.verified_rounded,
            iconColor: AppTheme.tossBlue,
            label: '광고 제거됨',
            trailing: const Text(
              '구매 완료',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.tossBlue,
              ),
            ),
            onTap: () {},
          );
        }
        return _ActionRow(
          icon: Icons.block_rounded,
          iconColor: AppTheme.tossBlue,
          label: '광고 제거',
          trailing: Text(
            billing.displayPrice,
            style: const TextStyle(
              fontSize: AppTheme.fontBody1,
              fontWeight: FontWeight.w700,
              color: AppTheme.tossBlue,
              letterSpacing: -0.2,
            ),
          ),
          onTap: _buyRemoveAds,
        );
      },
    );
  }

  Future<void> _buyRemoveAds() async {
    final billing = BillingService.instance;
    if (billing.product == null) {
      _showSnackBar('스토어 출시 후 이용할 수 있어요.');
      return;
    }
    final started = await billing.buyRemoveAds();
    if (!started && mounted) _showSnackBar('결제를 시작할 수 없습니다.');
    // 성공 시 BillingService.adRemoved → 배너 자동 숨김 + 이 행 자동 갱신.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      appBar: AppBar(
        backgroundColor: AppTheme.gray100,
        title: const Text('설정'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingPage,
          vertical: 12,
        ),
        children: [
          // ── 섹션 0: 위젯 ───────────────────────────────────────────────
          _SectionHeader(label: '위젯'),
          _SettingsCard(
            children: [
              _ActionRow(
                icon: Icons.widgets_rounded,
                iconColor: AppTheme.tossBlue,
                label: '위젯 설정',
                onTap: () => Navigator.of(context).pushNamed('/widget-setup'),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션 1: 주차 기록 ───────────────────────────────────────────
          _SectionHeader(label: '주차 기록'),
          _SettingsCard(
            children: [
              _ActionRow(
                icon: Icons.history_rounded,
                iconColor: AppTheme.tossBlue,
                label: '주차기록 보기',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ParkingHistoryPage(),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션 2: 자동화 ──────────────────────────────────────────────
          _SectionHeader(label: '자동화'),
          _SettingsCard(
            children: [
              // 블루투스 자동 감지 토글. 값 변경 즉시 네이티브 Receiver/Service 반영.
              _ToggleRow(
                icon: Icons.bluetooth_rounded,
                iconColor: AppTheme.tossBlue,
                label: '블루투스 자동 감지',
                subtitle: '연결 해제 시 자동으로 알림을 보냅니다',
                value: _btAutoEnabled,
                onChanged: _setBtAutoEnabled,
              ),
              const _Divider(),
              // 내 차 학습 상태. 운전 여부로 '내 차 BT'를 자동 인식한다.
              _InfoRow(
                icon: Icons.directions_car_rounded,
                label: '내 차',
                value: _taggedCar != null
                    ? '${_taggedCar!.name} (직접 지정)'
                    : (_learnedCar != null ? _learnedCar!.name : '학습 중'),
              ),
              if (_taggedCar == null && _learnedCar == null)
                const _HintText(
                  '운전 후 주차를 1~2회 반복하면 내 차 블루투스를 자동으로 '
                  '인식합니다. 그전까지는 오알림 방지를 위해 자동 알림을 보내지 '
                  '않습니다.',
                ),
              if (_taggedCar == null && _learnedCar != null) ...[
                const _Divider(),
                _ActionRow(
                  icon: Icons.refresh_rounded,
                  iconColor: AppTheme.gray500,
                  label: '차량 다시 학습하기',
                  onTap: _resetCarLearning,
                ),
              ],
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션: 의견 · 공유 ────────────────────────────────────────
          _SectionHeader(label: '의견 · 공유'),
          _SettingsCard(
            children: [
              _ActionRow(
                icon: Icons.feedback_outlined,
                iconColor: AppTheme.tossBlue,
                label: '피드백 보내기',
                onTap: _openFeedbackSheet,
              ),
              const _Divider(),
              _ActionRow(
                icon: Icons.star_rounded,
                iconColor: const Color(0xFFFFB400),
                label: '별점 주기',
                onTap: _openStoreForRating,
              ),
              const _Divider(),
              _ActionRow(
                icon: Icons.ios_share_rounded,
                iconColor: AppTheme.tossBlue,
                label: '친구에게 추천',
                onTap: _shareApp,
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션: 결제 ──────────────────────────────────────────────
          _SectionHeader(label: '결제'),
          _SettingsCard(children: [_buildRemoveAdsRow()]),

          const SizedBox(height: 28),

          // ── 섹션 3: 앱 ─────────────────────────────────────────────────
          _SectionHeader(label: '앱'),
          _SettingsCard(
            children: [
              _InfoRow(
                icon: Icons.info_outline_rounded,
                label: '버전',
                value: '1.0.0',
              ),
              const _Divider(),
              _ActionRow(
                icon: Icons.notifications_outlined,
                iconColor: AppTheme.gray500,
                label: '알림 설정',
                trailing: const Icon(Icons.open_in_new_rounded,
                    size: 16, color: AppTheme.gray500),
                onTap: () => AppSettings.openAppSettings(
                  type: AppSettingsType.notification,
                ),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션: 법적 고지 ─────────────────────────────────────────
          _SectionHeader(label: '법적 고지'),
          _SettingsCard(
            children: [
              _ActionRow(
                icon: Icons.privacy_tip_outlined,
                iconColor: AppTheme.tossBlue,
                label: '개인정보처리방침',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      const PolicyPage(doc: PolicyDocument.privacy),
                )),
              ),
              const _Divider(),
              _ActionRow(
                icon: Icons.location_on_outlined,
                iconColor: AppTheme.tossBlue,
                label: '위치기반서비스 이용약관',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      const PolicyPage(doc: PolicyDocument.location),
                )),
              ),
              const _Divider(),
              _ActionRow(
                icon: Icons.description_outlined,
                iconColor: AppTheme.tossBlue,
                label: '서비스 이용약관',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PolicyPage(doc: PolicyDocument.terms),
                )),
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션 4: 수동 설정 (자동 학습 우회) ───────────────────────
          // 자동 학습이 사용자의 차량을 아직 인식하지 못했거나, 즉시 직접 지정하고
          // 싶을 때 이미 페어링된 기기 중 하나를 '내 차'로 태깅하는 안전망.
          // 수동 태깅은 자동 학습보다 우선한다.
          // ※ 신규 BT 연결을 시도하지 않으며, OS 이벤트 필터링에만 쓰인다.
          _SectionHeader(label: '알림이 오지 않나요? (수동 설정)'),
          _SettingsCard(
            children: [
              _ActionRow(
                icon: Icons.directions_car_rounded,
                iconColor: AppTheme.tossBlue,
                label: _taggedCar != null
                    ? '내 차: ${_taggedCar!.name}'
                    : '내 차 블루투스 직접 선택',
                trailing: _taggedCar != null
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppTheme.tossBlue.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '등록됨',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.tossBlue,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.chevron_right_rounded,
                              size: 20, color: AppTheme.gray500),
                        ],
                      )
                    : null,
                onTap: _openManualCarPicker,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _taggedCar == null
                  ? '이미 페어링된 기기 중 내 차를 선택하면 해당 기기의 연결 해제만 감지해 알림을 보냅니다. (신규 연결 시도 없음)'
                  : 'MAC ${_taggedCar!.address} · 태그된 기기가 해제되면 자동 학습보다 우선해 즉시 알림합니다.',
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.gray500,
                height: 1.45,
                letterSpacing: -0.1,
              ),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

/// 수동 태깅된 차량 BT 기기의 화면 표기용 DTO.
class _TaggedCar {
  final String name;
  final String address;
  const _TaggedCar({required this.name, required this.address});
}

/// 페어링된 기기 목록을 표시하는 바텀시트.
///
/// ※ 이 화면은 조회 전용(Read-only) — 새로운 BT 연결/스캔을 일체 시도하지 않는다.
///    사용자는 OS 에 이미 페어링된 기기 중 하나를 '내 차'로 태깅하기만 한다.
class _PairedDevicePickerSheet extends StatelessWidget {
  final List<Map<String, String>> devices;
  final String? currentAddress;

  const _PairedDevicePickerSheet({
    required this.devices,
    required this.currentAddress,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 드래그 핸들
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: AppTheme.gray200,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              '내 차 블루투스 선택',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppTheme.gray900,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '이미 페어링된 기기 목록입니다. 신규 연결은 시도하지 않습니다.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.gray500,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Column(
                  children: const [
                    Icon(Icons.bluetooth_disabled_rounded,
                        size: 40, color: AppTheme.gray500),
                    SizedBox(height: 12),
                    Text(
                      '페어링된 기기가 없습니다.\n시스템 블루투스에서 차량과 먼저 페어링하세요.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.gray500,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  separatorBuilder: (_, __) => const Divider(
                    height: 1,
                    thickness: 0.5,
                    color: AppTheme.gray200,
                  ),
                  itemBuilder: (_, i) {
                    final d = devices[i];
                    final addr = d['address'] ?? '';
                    final name = d['name'] ?? '(이름 없음)';
                    final isSelected =
                        currentAddress != null && addr == currentAddress;
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(d),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: [
                            Icon(
                              isSelected
                                  ? Icons.bluetooth_connected_rounded
                                  : Icons.bluetooth_rounded,
                              size: 20,
                              color: isSelected
                                  ? AppTheme.tossBlue
                                  : AppTheme.gray500,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.gray900,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    addr,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.gray500,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              const Icon(Icons.check_rounded,
                                  size: 20, color: AppTheme.tossBlue),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (currentAddress != null) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(<String, String>{}),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: const Text(
                  '태깅 해제',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 레이아웃 서브 위젯 ────────────────────────────────────────────────────────

/// 섹션 헤더: 회색 소문자 레이블
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w600,
          color: AppTheme.gray500,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// 카드 컨테이너: 흰색 배경, 20dp 라운딩
class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

/// 탭 가능한 행: 왼쪽 아이콘 + 레이블 + 오른쪽 화살표
class _ActionRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final Widget? trailing;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    this.iconColor = AppTheme.gray900,
    required this.label,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingCard, vertical: 16),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: AppTheme.fontBody1,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.gray900,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            trailing ??
                const Icon(Icons.chevron_right_rounded,
                    size: 20, color: AppTheme.gray500),
          ],
        ),
      ),
    );
  }
}

/// 토글 행: 레이블 + 부제 + Switch
class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    this.iconColor = AppTheme.gray900,
    required this.label,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingCard, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 22, color: iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: AppTheme.fontBody1,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.gray900,
                    letterSpacing: -0.2,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.gray500,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppTheme.white,
            activeTrackColor: AppTheme.tossBlue,
          ),
        ],
      ),
    );
  }
}

/// 정보 행: 레이블 + 값(오른쪽 정렬)
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingCard, vertical: 16),
      child: Row(
        children: [
          Icon(icon, size: 22, color: AppTheme.gray500),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: AppTheme.fontBody1,
                fontWeight: FontWeight.w500,
                color: AppTheme.gray900,
                letterSpacing: -0.2,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: AppTheme.fontBody1,
              fontWeight: FontWeight.w500,
              color: AppTheme.gray500,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 카드 내부 보조 설명 문구 (학습 안내 등).
class _HintText extends StatelessWidget {
  final String text;
  const _HintText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(60, 0, 24, 14),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          height: 1.5,
          color: AppTheme.gray500,
          letterSpacing: -0.1,
        ),
      ),
    );
  }
}

/// 카드 내부 구분선 (Padding 포함)
class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 60), // 아이콘 너비(22) + 간격(14) + 좌패딩(24)
      child: Divider(height: 1, thickness: 0.5, color: AppTheme.gray200),
    );
  }
}

// ── 피드백 입력 시트 ──────────────────────────────────────────────────────────

/// 슬라이드 업 시트. 작성 내용을 mailto 로 [AppConfig.feedbackEmail] 에 전송한다.
class _FeedbackSheet extends StatefulWidget {
  const _FeedbackSheet();

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// mailto query 인코딩 헬퍼.
  ///
  /// 명세 v? — `Uri.encodeQueryComponent` 는 공백을 `+` 로 변환해 일부 메일
  /// 앱(아웃룩/일부 안드로이드 메일 앱)이 본문에 `+` 를 그대로 표시한다.
  /// `Uri.encodeComponent` 는 공백을 `%20` 으로 변환해 mailto RFC 6068 표준에
  /// 부합. 제목/본문이 정상 텍스트로 들어간다.
  static String _encodeQuery(Map<String, String> params) => params.entries
      .map((e) =>
          '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
      .join('&');

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('의견을 입력해주세요.')),
      );
      return;
    }
    setState(() => _sending = true);

    final uri = Uri(
      scheme: 'mailto',
      path: AppConfig.feedbackEmail,
      query: _encodeQuery({'subject': '[주차기억] 의견', 'body': text}),
    );

    bool launched;
    try {
      launched = await launchUrl(uri);
    } catch (_) {
      launched = false;
    }

    if (!mounted) return;
    setState(() => _sending = false);

    final messenger = ScaffoldMessenger.of(context);
    if (launched) {
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('소중한 의견 감사합니다!')),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('메일 앱을 열 수 없습니다.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppTheme.gray200,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            '피드백 보내기',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppTheme.gray900,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '실생활에서 "이런 앱 있으면 좋겠다" 싶은 아이디어나, 지금 이 앱에서 '
            '불편하거나 개선했으면 하는 점을 편하게 보내주세요. 보내주신 의견은 '
            '직접 검토해 앱에 반영해 드릴게요.',
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.gray500,
              height: 1.5,
              letterSpacing: -0.1,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            minLines: 4,
            maxLines: 8,
            textInputAction: TextInputAction.newline,
            // 실제 입력 글씨 — 검정. 명시 안 하면 다크 테마 등에서 흰색이 나와
            // 흰 fillColor 와 충돌해 안 보이는 사고가 난다.
            style: const TextStyle(
              fontSize: 15,
              color: AppTheme.gray900,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: '의견을 입력해주세요',
              // 플레이스홀더 — 회색. style 과 분리해 명시.
              hintStyle: const TextStyle(
                fontSize: 15,
                color: AppTheme.gray500,
                height: 1.5,
              ),
              filled: true,
              fillColor: const Color(0xFFF7F9FC),
              contentPadding: const EdgeInsets.all(14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE5E8EB)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFE5E8EB)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppTheme.tossBlue),
              ),
            ),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _sending ? null : _send,
            child: Container(
              height: AppTheme.btnPrimary,
              decoration: BoxDecoration(
                color: _sending ? AppTheme.gray200 : AppTheme.tossBlue,
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
              ),
              alignment: Alignment.center,
              child: _sending
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(AppTheme.white),
                      ),
                    )
                  : const Text(
                      '의견보내기',
                      style: TextStyle(
                        fontSize: AppTheme.fontBody1,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.white,
                        letterSpacing: -0.2,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
