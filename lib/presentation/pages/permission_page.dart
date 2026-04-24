import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';

/// 권한 안내 + 일괄 요청 온보딩 페이지.
///
/// ## 플로우 (토스·카카오뱅크 등 한국 앱 표준 패턴)
/// 1. 앱 최초 실행 시 이 페이지가 먼저 노출
/// 2. "모두 허용하기" → 카메라·위치·알림 3가지 OS 권한 다이얼로그 순차 표시
/// 3. 모두 허용 → 다음 단계(위젯 설정 or 홈)로 자동 이동
/// 4. 일부 거부 → 안내 다이얼로그: "설정으로 이동" or "나중에"
/// 5. "나중에" 선택해도 다음 단계 진행 (기능 제한 상태로 앱 사용 가능)
///
/// `is_permission_requested` SharedPrefs 플래그로 1회만 표시.
class PermissionPage extends StatefulWidget {
  const PermissionPage({super.key});

  @override
  State<PermissionPage> createState() => _PermissionPageState();
}

class _PermissionPageState extends State<PermissionPage> {
  bool _busy = false;

  /// 3가지 권한을 **하나씩** 순차 요청한 뒤 결과에 따라 안내/이동.
  ///
  /// `.request()` 를 리스트로 호출하면 OS가 순서를 보장하지 않아
  /// 알림 권한이 안내 페이지보다 먼저 뜨는 문제가 발생한다.
  /// 각 권한을 개별 `await`로 호출하면 이전 다이얼로그가 닫힌 뒤
  /// 다음 다이얼로그가 열려 사용자 경험이 자연스럽다.
  Future<void> _requestAll() async {
    if (_busy) return;
    setState(() => _busy = true);

    // 하나씩 순차 요청: 카메라 → 위치 → 블루투스 → 알림
    final cameraStatus = await Permission.camera.request();
    if (!mounted) return;

    final locationStatus = await Permission.location.request();
    if (!mounted) return;

    // Android 12+(API 31): BLUETOOTH_CONNECT 런타임 권한 필수.
    // 이 권한이 없으면 OS가 ACL_DISCONNECTED 브로드캐스트를 앱에 전달하지 않아
    // 블루투스 해제 시 주차 알림이 작동하지 않는다.
    final btStatus = await Permission.bluetoothConnect.request();
    if (!mounted) return;

    final notificationStatus = await Permission.notification.request();
    if (!mounted) return;

    setState(() => _busy = false);

    // 거부된 권한이 있는지 확인
    final denied = <Permission>[];
    if (!cameraStatus.isGranted) denied.add(Permission.camera);
    if (!locationStatus.isGranted) denied.add(Permission.location);
    if (!btStatus.isGranted) denied.add(Permission.bluetoothConnect);
    if (!notificationStatus.isGranted) denied.add(Permission.notification);

    if (denied.isNotEmpty) {
      // 거부 항목 있음 → 설정 유도 다이얼로그
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
        // 사용자가 설정에서 돌아오면 이 페이지가 그대로 보임 → 다시 "모두 허용하기" 가능
        return;
      }
    }

    // 모두 허용 또는 "나중에" → 다음 단계로
    await _markDoneAndProceed();
  }

  Future<void> _markDoneAndProceed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('is_permission_requested', true);

    if (!mounted) return;

    // ShellScreen 으로 이동. 위젯 미설정이면 ShellScreen 이 위젯 탭을 자동 선택.
    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(flex: 3),

              // ── 타이틀 ───────────────────────────────────────────────
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

              // ── 권한 항목 4개 ──────────────────────────────────────
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

              // ── CTA 버튼 ─────────────────────────────────────────
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
        ),
      ),
    );
  }
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
