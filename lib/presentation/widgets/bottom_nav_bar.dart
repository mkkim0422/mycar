import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// 하단 탭 아이템 정의.
class _NavItem {
  final IconData icon;
  final IconData iconSelected;
  final String label;

  const _NavItem({
    required this.icon,
    required this.iconSelected,
    required this.label,
  });
}

const _kItems = [
  _NavItem(
    icon: Icons.home_outlined,
    iconSelected: Icons.home_rounded,
    label: '홈',
  ),
  _NavItem(
    icon: Icons.widgets_outlined,
    iconSelected: Icons.widgets_rounded,
    label: '위젯',
  ),
  _NavItem(
    icon: Icons.settings_outlined,
    iconSelected: Icons.settings_rounded,
    label: '설정',
  ),
];

/// SnapPark 하단 내비게이션 바.
///
/// ## 스펙
/// - 전체 높이: [AppTheme.navBarHeight] = 78dp (아이콘 + 레이블 + safe area 제외한 시각 영역)
/// - 아이콘 크기: 28dp
/// - 활성화 색상: [AppTheme.tossBlue] (#0064FF)
/// - 비활성화 색상: [AppTheme.gray500] (#8B95A1)
/// - 배경: 흰색, 상단에 0.5px 구분선
class SnapParkNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const SnapParkNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.white,
        border: Border(
          top: BorderSide(color: AppTheme.gray200, width: 0.5),
        ),
      ),
      // 78dp = 시각 영역 (safe area 위)
      // safe area는 별도로 아래에 추가
      child: SizedBox(
        height: AppTheme.navBarHeight + bottomPadding,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: Row(
            children: List.generate(_kItems.length, (i) {
              return Expanded(child: _NavTab(
                item: _kItems[i],
                isSelected: i == currentIndex,
                onTap: () => onTap(i),
              ));
            }),
          ),
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  final _NavItem item;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavTab({
    required this.item,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppTheme.tossBlue : AppTheme.gray500;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 아이콘: 활성/비활성 전환 + 크기 28dp
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Icon(
              isSelected ? item.iconSelected : item.icon,
              key: ValueKey(isSelected),
              size: 28,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          // 레이블
          Text(
            item.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
              color: color,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }
}
