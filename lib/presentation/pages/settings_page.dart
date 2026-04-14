import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';

import '../../core/services/notification_service.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/parking_repository.dart';

/// 설정 화면.
///
/// ## 섹션 구성
/// 1. 주차 기록  — 저장된 기록 초기화
/// 2. 자동화     — 블루투스 자동 감지 토글 / BT 해제 테스트
/// 3. 앱         — 버전 정보 / 알림 설정 안내
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repo = ParkingRepository();

  // 블루투스 자동 감지 토글 상태 (로컬 UI state; BluetoothDisconnectReceiver는 항상 활성)
  bool _btAutoEnabled = true;

  Future<void> _clearRecord() async {
    final confirmed = await _showConfirmDialog(
      title: '기록 초기화',
      message: '저장된 주차 기록과 사진 경로가 삭제됩니다.\n계속하시겠어요?',
      actionLabel: '삭제',
    );
    if (!confirmed || !mounted) return;

    await _repo.clear();
    if (!mounted) return;
    _showSnackBar('주차 기록이 삭제되었습니다.');
  }

  Future<void> _simulateBtDisconnect() async {
    await NotificationService.instance.showParkingReminderNotification();
    if (mounted) _showSnackBar('블루투스 해제 알림을 발송했습니다.');
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String message,
    required String actionLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppTheme.gray900,
          ),
        ),
        content: Text(
          message,
          style: const TextStyle(
            fontSize: AppTheme.fontBody1,
            color: AppTheme.gray500,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소',
                style: TextStyle(color: AppTheme.gray500, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              actionLabel,
              style: const TextStyle(
                  color: Colors.red, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
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
          // ── 섹션 1: 주차 기록 ───────────────────────────────────────────
          _SectionHeader(label: '주차 기록'),
          _SettingsCard(
            children: [
              _ActionRow(
                icon: Icons.delete_outline_rounded,
                iconColor: Colors.red,
                label: '저장된 기록 초기화',
                labelColor: Colors.red,
                onTap: _clearRecord,
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션 2: 자동화 ──────────────────────────────────────────────
          _SectionHeader(label: '자동화'),
          _SettingsCard(
            children: [
              // 블루투스 자동 감지 토글
              _ToggleRow(
                icon: Icons.bluetooth_rounded,
                iconColor: AppTheme.tossBlue,
                label: '블루투스 자동 감지',
                subtitle: '연결 해제 시 자동으로 알림을 보냅니다',
                value: _btAutoEnabled,
                onChanged: (v) => setState(() => _btAutoEnabled = v),
              ),
              const _Divider(),
              // 테스트 버튼
              _ActionRow(
                icon: Icons.notifications_active_outlined,
                iconColor: AppTheme.gray500,
                label: 'BT 해제 알림 테스트',
                onTap: _simulateBtDisconnect,
              ),
            ],
          ),

          const SizedBox(height: 28),

          // ── 섹션 3: 앱 ─────────────────────────────────────────────────
          _SectionHeader(label: '앱'),
          _SettingsCard(
            children: [
              _InfoRow(
                icon: Icons.info_outline_rounded,
                label: '버전',
                value: '2.0.0',
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

          const SizedBox(height: 40),
        ],
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
  final Color labelColor;
  final Widget? trailing;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    this.iconColor = AppTheme.gray900,
    required this.label,
    this.labelColor = AppTheme.gray900,
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
                style: TextStyle(
                  fontSize: AppTheme.fontBody1,
                  fontWeight: FontWeight.w500,
                  color: labelColor,
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
