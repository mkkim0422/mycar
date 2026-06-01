import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/location_service.dart';
import '../../data/models/parking_data.dart';
import '../../data/repositories/parking_repository.dart';
import '../widgets/ad_banner.dart';

/// 카메라가 pop 한 결과(사진 경로 + 사전 채움 zone) 를 받아 사용자가 지상/지하
/// · 층 · 구역을 검토 후 저장하는 풀스크린 페이지.
///
/// 카메라 화면은 순정(미리보기+가이드+셔터+AR 박스만) 이고 모든 입력은 이
/// 페이지에서 이뤄진다 (v11 명세).
///
/// 닫는 흐름:
///   - [저장] → `Navigator.pop(true)` → home reload
///   - [다시 촬영] / back → `Navigator.pop(false)` → 카메라 재진입
class ParkingInputPage extends StatefulWidget {
  final String photoPath;
  final String prefilledZone;

  /// 카메라가 추출한 층 종류 ('지하' / '지상' / null).
  /// null 이면 사용자 직접 토글 (default 지하 유지).
  final String? prefilledFloorType;

  /// 카메라가 추출한 층 숫자 ('1'~'9' / null).
  final String? prefilledFloorNum;

  const ParkingInputPage({
    super.key,
    required this.photoPath,
    required this.prefilledZone,
    this.prefilledFloorType,
    this.prefilledFloorNum,
  });

  @override
  State<ParkingInputPage> createState() => _ParkingInputPageState();
}

class _ParkingInputPageState extends State<ParkingInputPage> {
  final _parkingRepository = ParkingRepository();
  final _zoneCtrl = TextEditingController();
  final _floorCtrl = TextEditingController();
  bool _isBasement = true;
  bool _isSaving = false;
  Future<LocationSnapshot>? _pendingLocation;

  @override
  void initState() {
    super.initState();
    // 명세: "기존에 수동 입력되어 있던 값에 연연하지 말고 새로 인식된 결과로
    //  화면 UI(토글/층/구역)를 즉시 무조건 갱신". 다시 촬영 → 새 인스턴스라
    //  initState 가 다시 호출되며 카메라 결과로 모든 필드를 덮어쓴다.
    if (widget.prefilledZone.isNotEmpty) {
      _zoneCtrl.text = widget.prefilledZone;
    }
    if (widget.prefilledFloorNum != null &&
        widget.prefilledFloorNum!.isNotEmpty) {
      _floorCtrl.text = widget.prefilledFloorNum!;
    }
    if (widget.prefilledFloorType != null) {
      _isBasement = widget.prefilledFloorType == '지하';
    }
    _pendingLocation = LocationService.fetchCurrent(prewarm: true);
  }

  @override
  void dispose() {
    _zoneCtrl.dispose();
    _floorCtrl.dispose();
    super.dispose();
  }

  String _composedFloor() {
    final raw = _floorCtrl.text.trim();
    if (raw.isEmpty) return '-';
    final prefix = _isBasement ? '지하' : '지상';
    if (RegExp(r'^\d+$').hasMatch(raw)) return '$prefix $raw층';
    return '$prefix $raw';
  }

  String _composedZone() {
    final raw = _zoneCtrl.text.trim();
    return raw.isEmpty ? '-' : raw;
  }

  Future<Future<LocationSnapshot>> _ensureLocationFuture(
    Future<LocationSnapshot>? existing,
  ) async {
    if (existing == null) return LocationService.fetchCurrent();
    try {
      final snap = await existing.timeout(Duration.zero);
      if (snap.hasCoords) return existing;
      return LocationService.fetchCurrent();
    } on TimeoutException {
      return existing;
    }
  }

  void _runBackgroundLocationUpdate(DateTime timestamp) {
    () async {
      try {
        final snap = await LocationService.fetchCurrent().timeout(
          const Duration(seconds: 30),
          onTimeout: () => LocationSnapshot.empty,
        );
        if (!snap.hasCoords) return;
        await _parkingRepository.updateLocation(
          timestamp: timestamp,
          latitude: snap.latitude,
          longitude: snap.longitude,
          address: snap.address,
        );
      } catch (e) {
        debugPrint('[Input] BG 위치 업데이트 예외: $e');
      }
    }();
  }

  Future<void> _onSave() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      _pendingLocation = await _ensureLocationFuture(_pendingLocation);
      final timestamp = DateTime.now();
      await _parkingRepository.save(ParkingData(
        floor: _composedFloor(),
        zone: _composedZone(),
        photoPath: widget.photoPath,
        timestamp: timestamp,
      ));
      _runBackgroundLocationUpdate(timestamp);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      debugPrint('[Input] 저장 실패: $e');
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _onRetry() => Navigator.of(context).pop(false);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF191F28)),
          onPressed: _onRetry,
        ),
        title: const Text(
          '주차 정보 입력',
          style: TextStyle(
            color: Color(0xFF191F28),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      // 저장 버튼은 스크롤 영역 안에 있고, 광고는 화면 최하단에 고정.
      // 둘이 분리되어 있어 저장 버튼 미스탭 우려가 없다(홈 ShellScreen 과 동일 패턴).
      bottomNavigationBar: const AdBanner(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PhotoPreview(photoPath: widget.photoPath),
              const SizedBox(height: 24),
              const _SectionLabel('지상 / 지하'),
              const SizedBox(height: 8),
              _ElevationToggle(
                isBasement: _isBasement,
                onChanged: (b) => setState(() => _isBasement = b),
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionLabel('층'),
                        const SizedBox(height: 8),
                        _Input(
                          controller: _floorCtrl,
                          hint: '예: 2',
                          enabled: !_isSaving,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _SectionLabel('구역'),
                        const SizedBox(height: 8),
                        _Input(
                          controller: _zoneCtrl,
                          hint: 'C13구역',
                          enabled: !_isSaving,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: _Btn(
                      label: '다시 촬영',
                      color: const Color(0xFFF2F4F6),
                      textColor: const Color(0xFF333D4B),
                      onTap: _isSaving ? null : _onRetry,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Btn(
                      label: _isSaving ? '저장 중...' : '저장',
                      color: const Color(0xFF0064FF),
                      onTap: _isSaving ? null : _onSave,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  UI 컴포넌트
// ─────────────────────────────────────────────────────────────────────────────

class _PhotoPreview extends StatelessWidget {
  final String photoPath;
  const _PhotoPreview({required this.photoPath});

  @override
  Widget build(BuildContext context) {
    const double height = 240;
    final BorderRadius radius = BorderRadius.circular(16);
    if (photoPath.isEmpty) {
      return _placeholder(radius, height, '사진 경로가 비어있어요');
    }
    return ClipRRect(
      borderRadius: radius,
      child: Image.file(
        File(photoPath),
        width: double.infinity,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) =>
            _placeholder(radius, height, '사진을 불러올 수 없어요'),
      ),
    );
  }

  static Widget _placeholder(BorderRadius radius, double h, String text) {
    return Container(
      width: double.infinity,
      height: h,
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F6),
        borderRadius: radius,
        border: Border.all(color: const Color(0xFFE5E8EB)),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.image_outlined,
              color: Color(0xFFB0B8C1), size: 36),
          const SizedBox(height: 8),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFF8B95A1),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xFF333D4B),
        fontSize: 13,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _ElevationToggle extends StatelessWidget {
  final bool isBasement;
  final ValueChanged<bool> onChanged;
  const _ElevationToggle({required this.isBasement, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F4F6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ToggleCell(
              label: '지하',
              selected: isBasement,
              onTap: () => onChanged(true),
            ),
          ),
          Expanded(
            child: _ToggleCell(
              label: '지상',
              selected: !isBasement,
              onTap: () => onChanged(false),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleCell extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ToggleCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0064FF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : const Color(0xFF8B95A1),
          ),
        ),
      ),
    );
  }
}

class _Input extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  const _Input({
    required this.controller,
    required this.hint,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: TextField(
        controller: controller,
        enabled: enabled,
        textInputAction: TextInputAction.done,
        keyboardType: TextInputType.visiblePassword,
        maxLength: 6,
        buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF191F28),
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            color: Color(0xFFB0B8C1),
            fontWeight: FontWeight.w500,
            fontSize: 14,
          ),
          filled: true,
          fillColor: const Color(0xFFF2F4F6),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF0064FF), width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback? onTap;
  const _Btn({
    required this.label,
    required this.color,
    this.textColor = Colors.white,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1.0,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
