import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../core/config/app_config.dart';
import '../../core/services/billing_service.dart';

/// 화면 하단 고정 배너.
///
/// 기존 하단 네비게이션 바가 있던 자리에 배치된다(ShellScreen 의
/// `bottomNavigationBar` 슬롯). 적응형 앵커 배너 사이즈를 사용하고,
/// 광고가 네트워크로 비동기 로드되는 동안 슬롯 높이를 미리 잡아 둬
/// "광고 도착 시 콘텐츠가 위로 밀리는" 레이아웃 점프를 방지한다.
///
/// ## 노출 정책 (AppConfig 와 일치)
/// - **debug**  : 항상 Google 공식 테스트 광고. (실제 광고 노출 = 계정 정지)
/// - **release** : [AppConfig.isAdmobConfigured] 가 true 일 때만 실제 광고.
///   실제 unit ID 미설정 시 배너 자체를 숨겨 테스트 광고가 운영 배포로
///   나가지 않게 한다.
/// - **iOS**    : 현재 Android 우선. iOS 는 Info.plist 미설정 상태이므로
///   배너를 만들지 않는다(초기화 크래시 방지). 추후 iOS 설정 시 이 가드 해제.
class AdBanner extends StatefulWidget {
  const AdBanner({super.key});

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  AdSize? _size;
  bool _isLoaded = false;

  /// 가드 미충족(iOS·release 미설정) 또는 로드 실패 → 영역 자체를 접는다.
  bool _dismissed = false;

  bool _loadStarted = false;

  /// debug 는 테스트 ID, release 는 실제 ID.
  String get _unitId => kReleaseMode
      ? AppConfig.admobRealBannerUnitId
      : AppConfig.admobTestBannerUnitId;

  @override
  void initState() {
    super.initState();
    // 광고 제거 구매 시 즉시 배너를 내린다(앱 재시작 불필요).
    BillingService.instance.adRemoved.addListener(_onAdRemovedChanged);
  }

  void _onAdRemovedChanged() {
    if (BillingService.instance.adRemoved.value) {
      _ad?.dispose();
      _ad = null;
      _dismiss();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery(화면 폭) 가 필요하므로 didChangeDependencies 에서 1회 로드.
    if (!_loadStarted) {
      _loadStarted = true;
      _loadAd();
    }
  }

  Future<void> _loadAd() async {
    // iOS: Info.plist 미설정 → 초기화/배너 생성 금지(크래시 방지).
    if (!Platform.isAndroid) {
      _dismiss();
      return;
    }
    // release 인데 실제 광고 단위 ID 미설정 → 배너 숨김(테스트 광고 운영 배포 방지).
    if (kReleaseMode && !AppConfig.isAdmobConfigured) {
      _dismiss();
      return;
    }
    // 광고 제거 구매됨 → 배너 생성하지 않음.
    if (BillingService.instance.adRemoved.value) {
      _dismiss();
      return;
    }

    // 화면 진입 애니메이션/첫 프레임과 AdView inflate 충돌 완화(짧은 지연).
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    final width = MediaQuery.sizeOf(context).width.truncate();
    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSizeWithOrientation(
      Orientation.portrait,
      width,
    );
    if (!mounted || size == null) {
      _dismiss();
      return;
    }

    final ad = BannerAd(
      size: size,
      adUnitId: _unitId,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _isLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          _ad = null;
          _dismiss();
        },
      ),
    );

    setState(() => _size = size);
    await ad.load();
    _ad = ad;
  }

  void _dismiss() {
    if (mounted && !_dismissed) setState(() => _dismissed = true);
  }

  @override
  void dispose() {
    BillingService.instance.adRemoved.removeListener(_onAdRemovedChanged);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    // 사이즈 산정 전: 표준 배너 높이(50)를 예약해 점프 최소화.
    final reservedHeight = _size?.height.toDouble() ?? 50.0;

    return SafeArea(
      top: false,
      child: SizedBox(
        width: double.infinity,
        height: reservedHeight,
        child: (_isLoaded && _ad != null)
            ? AdWidget(ad: _ad!)
            : const SizedBox.shrink(),
      ),
    );
  }
}
