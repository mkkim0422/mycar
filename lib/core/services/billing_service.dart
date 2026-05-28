import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// 광고 제거 인앱 결제 서비스 (Google Play Billing).
///
/// ## 책임
/// - 앱 시작 시 영속 플래그를 먼저 로드해 **오프라인에서도 즉시** 광고 숨김 보장
/// - 스토어 가용 시 상품 조회 / 기존 구매 복원 / 구매 스트림 구독
/// - 구매·복원 성공 → [adRemoved] = true + SharedPreferences 영속화
///
/// [adRemoved] 는 [AdBanner] 와 설정 화면이 함께 구독한다(구매 즉시 배너 숨김).
///
/// 실제 결제 동작에는 Play Console 에 [AppConfig.removeAdsProductId] 와 동일한
/// 비소비성 상품 등록이 필요하다(미등록 시 [product] = null → 가격 폴백 표시).
class BillingService {
  BillingService._();
  static final BillingService instance = BillingService._();

  /// SharedPreferences 영속 키 (AdBanner 도 이 의미를 공유).
  static const String _kAdRemovedKey = 'ad_removed';

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  bool _initialized = false;

  /// 광고 제거 구매 여부. true → 광고 비노출.
  final ValueNotifier<bool> adRemoved = ValueNotifier<bool>(false);

  /// 초기화(상품 조회/복원)가 끝났는지. 설정 화면이 가격 로딩 표시에 사용.
  final ValueNotifier<bool> ready = ValueNotifier<bool>(false);

  /// 광고 제거 상품 정보(가격 표시·구매에 사용). 스토어 미설정 시 null.
  ProductDetails? product;

  /// 표시용 가격 — 스토어 가격 우선, 없으면 폴백(₩1,900).
  String get displayPrice => product?.price ?? AppConfig.removeAdsFallbackPrice;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // 1) 영속 플래그 먼저 — 네트워크/스토어 없이도 광고 즉시 숨김.
    final prefs = await SharedPreferences.getInstance();
    adRemoved.value = prefs.getBool(_kAdRemovedKey) ?? false;

    // 2) 스토어 가용 여부.
    bool available;
    try {
      available = await _iap.isAvailable();
    } catch (_) {
      available = false;
    }
    if (!available) {
      ready.value = true; // 스토어 없음 → 폴백 가격으로 표시
      return;
    }

    // 3) 구매/복원 결과 스트림 구독.
    _sub = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});

    // 4) 상품 조회.
    try {
      final resp =
          await _iap.queryProductDetails({AppConfig.removeAdsProductId});
      if (resp.productDetails.isNotEmpty) {
        product = resp.productDetails.first;
      }
    } catch (_) {}

    // 5) 기존 구매 복원(앱 재설치/기기 변경 대비). 결과는 스트림으로 수신.
    try {
      await _iap.restorePurchases();
    } catch (_) {}

    ready.value = true;
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.productID != AppConfig.removeAdsProductId) continue;
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _grantAdRemoved();
        case PurchaseStatus.pending:
        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
          break;
      }
      // 완료 처리하지 않으면 스토어가 환불 처리할 수 있다.
      if (p.pendingCompletePurchase) {
        try {
          await _iap.completePurchase(p);
        } catch (_) {}
      }
    }
  }

  Future<void> _grantAdRemoved() async {
    if (adRemoved.value) return;
    adRemoved.value = true; // → AdBanner 즉시 숨김 (리스너)
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAdRemovedKey, true);
  }

  /// 광고 제거 구매 시작. 반환값: 결제 플로우를 시작할 수 있었는지.
  /// 성공 결과는 [adRemoved] 로 비동기 반영된다.
  Future<bool> buyRemoveAds() async {
    final pd = product;
    if (pd == null) return false;
    try {
      return await _iap.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: pd),
      );
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _sub?.cancel();
  }
}
