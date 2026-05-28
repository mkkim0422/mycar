import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import 'policy_page.dart';

/// 약관 동의 + 권한 안내·일괄 요청 온보딩 페이지.
///
/// ## 플로우 (PIPA + 위치정보법 컴플라이언스)
/// 1. 앱 최초 실행 시 이 페이지가 먼저 노출
/// 2. **필수 동의 2종** (개인정보처리방침 + 위치기반서비스 이용약관) 체크 필수
/// 3. **선택 동의 1종** (서비스 이용약관) — 체크 없어도 진행 가능
/// 4. [동의하고 계속하기] → 권한 안내 단계로 진행
/// 5. "모두 허용하기" → 카메라·위치·BT·알림 4가지 OS 권한 다이얼로그 순차 표시
/// 6. 모두 허용 → 다음 단계(위젯 설정 or 홈)로 자동 이동
/// 7. 일부 거부 → 안내 다이얼로그: "설정으로 이동" or "나중에"
///
/// SharedPreferences 키:
///   - `is_permission_requested` : 1회 노출 가드
///   - `terms_agreed_at`         : 동의 시각 (위치정보법 16조 — 6개월 보관)
class PermissionPage extends StatefulWidget {
  const PermissionPage({super.key});

  @override
  State<PermissionPage> createState() => _PermissionPageState();
}

class _PermissionPageState extends State<PermissionPage> {
  bool _busy = false;

  /// 1단계: 약관 동의, 2단계: 권한 안내·요청.
  int _step = 0;

  // 동의 체크 상태
  bool _agreePrivacy = false;
  bool _agreeLocation = false;
  bool _agreeTerms = false; // 선택

  bool get _canProceed => _agreePrivacy && _agreeLocation;

  Future<void> _goToPermissionStep() async {
    if (!_canProceed) return;
    // 동의 시각 저장 (위치정보법 제16조 제2항 — 수집·이용·제공사실 확인자료).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'terms_agreed_at', DateTime.now().toIso8601String());
    await prefs.setBool('agreed_privacy', _agreePrivacy);
    await prefs.setBool('agreed_location', _agreeLocation);
    await prefs.setBool('agreed_terms', _agreeTerms);
    if (!mounted) return;
    setState(() => _step = 1);
  }

  /// 4가지 권한을 **하나씩** 순차 요청한 뒤 결과에 따라 안내/이동.
  Future<void> _requestAll() async {
    if (_busy) return;
    setState(() => _busy = true);

    final cameraStatus = await Permission.camera.request();
    if (!mounted) return;
    final locationStatus = await Permission.location.request();
    if (!mounted) return;
    // Android 12+(API 31): BLUETOOTH_CONNECT 런타임 권한 필수.
    final btStatus = await Permission.bluetoothConnect.request();
    if (!mounted) return;
    final notificationStatus = await Permission.notification.request();
    if (!mounted) return;

    setState(() => _busy = false);

    final denied = <Permission>[];
    if (!cameraStatus.isGranted) denied.add(Permission.camera);
    if (!locationStatus.isGranted) denied.add(Permission.location);
    if (!btStatus.isGranted) denied.add(Permission.bluetoothConnect);
    if (!notificationStatus.isGranted) denied.add(Permission.notification);

    if (denied.isNotEmpty) {
      final goSettings = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text(
            '권한이 필요합니다',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          content: const Text(
            '일부 권한이 거부되었습니다.\n'
            '앱의 모든 기능을 이용하려면\n'
            '설정에서 직접 허용해 주세요.',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                '나중에',
                style: TextStyle(color: AppTheme.gray500),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                '설정으로 이동',
                style: TextStyle(
                    color: AppTheme.tossBlue, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
      if (goSettings == true) {
        AppSettings.openAppSettings();
        return;
      }
    }

    await _markDoneAndProceed();
  }

  Future<void> _markDoneAndProceed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_permission_requested', true);
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      body: SafeArea(
        child: _step == 0 ? _buildConsentStep() : _buildPermissionStep(),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Step 0 — 약관 동의
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildConsentStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 36),
          const Text(
            '서비스 이용을 위해\n약관에 동의해 주세요',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: AppTheme.gray900,
              height: 1.35,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '데이터는 회원님의 단말기 안에만 저장되며\n외부 서버로 전송하지 않습니다',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: AppTheme.gray500,
            ),
          ),

          const SizedBox(height: 36),

          // ── 전체 동의 ────────────────────────────────────────
          _AllAgreeBar(
            checked:
                _agreePrivacy && _agreeLocation && _agreeTerms,
            onTap: () {
              final newAll = !(_agreePrivacy &&
                  _agreeLocation &&
                  _agreeTerms);
              setState(() {
                _agreePrivacy = newAll;
                _agreeLocation = newAll;
                _agreeTerms = newAll;
              });
            },
          ),

          const SizedBox(height: 16),

          // ── 개별 동의 ────────────────────────────────────────
          _ConsentRow(
            label: '개인정보처리방침 동의',
            required: true,
            checked: _agreePrivacy,
            onChanged: (v) => setState(() => _agreePrivacy = v),
            onView: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const PolicyPage(doc: PolicyDocument.privacy),
            )),
          ),
          const _ConsentDivider(),
          _ConsentRow(
            label: '위치기반서비스 이용약관 동의',
            required: true,
            checked: _agreeLocation,
            onChanged: (v) => setState(() => _agreeLocation = v),
            onView: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const PolicyPage(doc: PolicyDocument.location),
            )),
          ),
          const _ConsentDivider(),
          _ConsentRow(
            label: '서비스 이용약관 동의',
            required: false,
            checked: _agreeTerms,
            onChanged: (v) => setState(() => _agreeTerms = v),
            onView: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const PolicyPage(doc: PolicyDocument.terms),
            )),
          ),

          const Spacer(),

          // ── CTA 버튼 ─────────────────────────────────────────
          GestureDetector(
            onTap: _canProceed ? _goToPermissionStep : null,
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                gradient: _canProceed
                    ? const LinearGradient(
                        colors: [Color(0xFF0064FF), Color(0xFF7C5CFC)],
                      )
                    : null,
                color: _canProceed ? null : AppTheme.gray200,
                borderRadius: BorderRadius.circular(28),
                boxShadow: _canProceed
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
              child: const Text(
                '동의하고 계속하기',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  Step 1 — 권한 안내·요청
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildPermissionStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 3),
          const Text(
            '앱을 사용하기 위해\n다음 권한이 필요합니다',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: AppTheme.gray900,
              height: 1.35,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 36),
          const _PermissionItem(
            icon: Icons.camera_alt_rounded,
            title: '카메라',
            desc: '주차 구역 사진 촬영을 위해 필요합니다',
          ),
          const SizedBox(height: 20),
          const _PermissionItem(
            icon: Icons.location_on_rounded,
            title: '위치',
            desc: '주차 지점 GPS 좌표 저장을 위해 필요합니다',
          ),
          const SizedBox(height: 20),
          const _PermissionItem(
            icon: Icons.bluetooth_rounded,
            title: '블루투스',
            desc: '차량 블루투스 해제 감지를 위해 필요합니다',
          ),
          const SizedBox(height: 20),
          const _PermissionItem(
            icon: Icons.notifications_rounded,
            title: '알림',
            desc: '주차 알림을 보내기 위해 필요합니다',
          ),
          const Spacer(flex: 5),
          GestureDetector(
            onTap: _busy ? null : _requestAll,
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0064FF), Color(0xFF7C5CFC)],
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.tossBlue.withValues(alpha: 0.30),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text(
                      '모두 허용하기',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 전체 동의 한 줄.
class _AllAgreeBar extends StatelessWidget {
  final bool checked;
  final VoidCallback onTap;
  const _AllAgreeBar({required this.checked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: checked ? AppTheme.tossBlue : AppTheme.gray200,
            width: checked ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              checked
                  ? Icons.check_circle_rounded
                  : Icons.check_circle_outline_rounded,
              color: checked ? AppTheme.tossBlue : AppTheme.gray200,
              size: 24,
            ),
            const SizedBox(width: 12),
            const Text(
              '약관 전체 동의',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppTheme.gray900,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 개별 동의 한 줄.
class _ConsentRow extends StatelessWidget {
  final String label;
  final bool required;
  final bool checked;
  final ValueChanged<bool> onChanged;
  final VoidCallback onView;

  const _ConsentRow({
    required this.label,
    required this.required,
    required this.checked,
    required this.onChanged,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!checked),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        child: Row(
          children: [
            Icon(
              checked
                  ? Icons.check_circle_rounded
                  : Icons.check_circle_outline_rounded,
              color: checked ? AppTheme.tossBlue : AppTheme.gray200,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTheme.gray900,
                    letterSpacing: -0.2,
                  ),
                  children: [
                    TextSpan(
                      text: required ? '(필수) ' : '(선택) ',
                      style: TextStyle(
                        color:
                            required ? AppTheme.tossBlue : AppTheme.gray500,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    TextSpan(text: label),
                  ],
                ),
              ),
            ),
            GestureDetector(
              onTap: onView,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  '보기',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.gray500,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentDivider extends StatelessWidget {
  const _ConsentDivider();
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, color: Color(0xFFEEF1F4));
}

/// 권한 안내 한 줄 아이템.
class _PermissionItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String desc;

  const _PermissionItem({
    required this.icon,
    required this.title,
    required this.desc,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: AppTheme.tossBlue.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: AppTheme.tossBlue, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.gray900,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                desc,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.gray500,
                  letterSpacing: -0.1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
