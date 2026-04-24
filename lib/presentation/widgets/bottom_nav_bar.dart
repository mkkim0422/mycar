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
    icon: Icons.local_parking_outlined,
    iconSelected: Icons.local_parking_rounded,
    label: '내차위치',
  ),
  _NavItem(
    icon: Icons.settings_outlined,
    iconSelected: Icons.settings_rounded,
    label: '설정',
  ),
];

/// SnapPark 하단 내비게이션 바 (2탭: 내차위치 / 설정).
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
      child: SizedBox(
        height: AppTheme.navBarHeight + bottomPadding,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
          child: Row(
            children: List.generate(_kItems.length, (i) {
              return Expanded(
                child: _NavTab(
                  item: _kItems[i],
                  isSelected: i == currentIndex,
                  onTap: () => onTap(i),
                ),
              );
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
