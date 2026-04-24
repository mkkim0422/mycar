import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/parking_data.dart';
import '../../data/repositories/parking_repository.dart';

/// 주차 기록 목록 페이지.
///
/// - 리스트: "2026년 4월 19일(토) 오후 3:22" 형태
/// - 체크박스 선택 → 하단 플로팅 삭제 버튼
/// - 아이템 탭 → 전체화면 사진 뷰어
/// - 빈 상태 → "저장된 주차정보가 없습니다"
class ParkingHistoryPage extends StatefulWidget {
  const ParkingHistoryPage({super.key});

  @override
  State<ParkingHistoryPage> createState() => _ParkingHistoryPageState();
}

class _ParkingHistoryPageState extends State<ParkingHistoryPage> {
  final _repo = ParkingRepository();
  List<ParkingData> _records = [];
  final Set<int> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _repo.getAll();
    if (!mounted) return;
    setState(() {
      _records = all;
      _selected.clear();
      _loading = false;
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
        title: const Text(
          '기록 삭제',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppTheme.gray900,
          ),
        ),
        content: Text(
          '선택한 ${_selected.length}건의 기록을 삭제하시겠습니까?',
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
                style: TextStyle(
                    color: AppTheme.gray500, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제',
                style: TextStyle(
                    color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await _repo.deleteAt(_selected);
    await _load();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('선택한 기록이 삭제되었습니다.',
            style: TextStyle(fontWeight: FontWeight.w500)),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.gray900,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusChip)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
    );
  }

  void _toggleSelect(int index) {
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        _selected.add(index);
      }
    });
  }

  /// 전체 선택 토글. 이미 모두 선택된 상태라면 전부 해제한다.
  void _toggleSelectAll() {
    setState(() {
      if (_records.isNotEmpty && _selected.length == _records.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(List.generate(_records.length, (i) => i));
      }
    });
  }

  void _viewPhoto(ParkingData data) {
    final path = data.photoPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) return;
    Navigator.of(context).push(_FullscreenPhotoRoute(path: path));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.gray100,
      appBar: AppBar(
        backgroundColor: AppTheme.gray100,
        title: const Text('주차기록 보기'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.tossBlue))
          : _records.isEmpty
              ? _buildEmpty()
              : _buildList(),
      floatingActionButton: _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _deleteSelected,
              backgroundColor: Colors.red,
              icon: const Icon(Icons.delete_rounded, color: Colors.white),
              label: Text(
                '${_selected.length}건 삭제',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_rounded, size: 56, color: AppTheme.gray500),
          SizedBox(height: 16),
          Text(
            '저장된 주차정보가 없습니다',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.gray500,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return Column(
      children: [
        _buildSelectAllHeader(),
        Expanded(child: _buildListItems()),
      ],
    );
  }

  /// 리스트 상단의 "전체 선택" 헤더. 스크롤과 무관하게 항상 보이도록 고정.
  ///
  /// - 아무것도 선택 안됨 → 빈 체크박스
  /// - 일부만 선택됨     → 삼선 상태(tristate dash)
  /// - 모두 선택됨       → 체크됨
  Widget _buildSelectAllHeader() {
    final total = _records.length;
    final selectedCount = _selected.length;
    final allSelected = total > 0 && selectedCount == total;
    final partiallySelected = selectedCount > 0 && !allSelected;

    // tristate Checkbox: null = dash, false = empty, true = check
    final bool? value = allSelected
        ? true
        : (partiallySelected ? null : false);

    return InkWell(
      onTap: total == 0 ? null : _toggleSelectAll,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Transform.scale(
                scale: 1.35,
                child: Checkbox(
                  tristate: true,
                  value: value,
                  onChanged:
                      total == 0 ? null : (_) => _toggleSelectAll(),
                  activeColor: AppTheme.tossBlue,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6)),
                  side:
                      const BorderSide(color: AppTheme.gray500, width: 1.5),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              allSelected ? '전체 해제' : '전체 선택',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppTheme.gray900,
                letterSpacing: -0.2,
              ),
            ),
            const Spacer(),
            Text(
              '$selectedCount / $total',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.gray500,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListItems() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
      itemCount: _records.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final data = _records[i];
        final isChecked = _selected.contains(i);

        return Container(
          decoration: BoxDecoration(
            color: isChecked
                ? AppTheme.tossBlue.withValues(alpha: 0.06)
                : AppTheme.white,
            borderRadius: BorderRadius.circular(16),
            border: isChecked
                ? Border.all(
                    color: AppTheme.tossBlue.withValues(alpha: 0.3), width: 1)
                : null,
          ),
          child: InkWell(
            // 행 전체 탭 → 선택 토글. 사진 보기는 썸네일 탭으로만 진입.
            onTap: () => _toggleSelect(i),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Row(
                children: [
                  // ── 체크박스 (확대) ───────────────────────────────
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: Transform.scale(
                      scale: 1.35,
                      child: Checkbox(
                        value: isChecked,
                        onChanged: (_) => _toggleSelect(i),
                        activeColor: AppTheme.tossBlue,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6)),
                        side: const BorderSide(
                            color: AppTheme.gray500, width: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // ── 썸네일 (탭 → 사진 뷰어) ───────────────────────
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _viewPhoto(data),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: _buildThumbnail(data.photoPath),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),

                  // ── 텍스트 정보 ──────────────────────────────────
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formatDate(data.timestamp),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.gray900,
                            letterSpacing: -0.3,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _buildSubtitle(data),
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.gray500,
                            letterSpacing: -0.1,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildThumbnail(String? photoPath) {
    if (photoPath != null &&
        photoPath.isNotEmpty &&
        File(photoPath).existsSync()) {
      return Image.file(
        File(photoPath),
        fit: BoxFit.cover,
        cacheWidth: 200,
      );
    }
    return Container(
      color: AppTheme.gray200,
      child: const Icon(Icons.image_outlined, color: AppTheme.gray500, size: 24),
    );
  }

  static const _weekdays = ['일', '월', '화', '수', '목', '금', '토'];

  String _formatDate(DateTime dt) {
    final dow = _weekdays[dt.weekday % 7];
    final ampm = dt.hour < 12 ? '오전' : '오후';
    final hour12 = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}년 ${dt.month}월 ${dt.day}일($dow) $ampm $hour12:$min';
  }

  String _buildSubtitle(ParkingData data) {
    final parts = <String>[];
    if (data.floor.isNotEmpty && data.floor != '-') parts.add(data.floor);
    if (data.zone.isNotEmpty && data.zone != '-') {
      final z = data.zone.endsWith('구역') ? data.zone : '${data.zone}구역';
      parts.add(z);
    }
    if (data.address != null && data.address!.isNotEmpty) {
      parts.add(data.address!);
    }
    return parts.isEmpty ? '주차 기록' : parts.join(' · ');
  }
}

// ── Fullscreen Photo Viewer ─────────────────────────────────────────────────

class _FullscreenPhotoRoute extends PageRouteBuilder<void> {
  _FullscreenPhotoRoute({required String path})
      : super(
          opaque: false,
          barrierColor: Colors.black,
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 150),
          pageBuilder: (_, __, ___) => _FullscreenPhotoView(path: path),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop(),
            child: InteractiveViewer(
              maxScale: 4,
              child: Center(
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 4,
            left: 4,
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 28),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
