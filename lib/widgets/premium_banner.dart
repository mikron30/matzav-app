import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/monetization_config.dart';
import '../services/ads_service.dart';
import '../services/premium_service.dart';

/// An anchored adaptive banner that is visible only to confirmed free users.
class PremiumAwareBanner extends StatefulWidget {
  const PremiumAwareBanner({super.key});

  @override
  State<PremiumAwareBanner> createState() => _PremiumAwareBannerState();
}

class _PremiumAwareBannerState extends State<PremiumAwareBanner> {
  final AdsService _adsService = AdsService.instance;
  final PremiumService _premiumService = PremiumService.instance;

  BannerAd? _banner;
  BannerAd? _loadingBanner;
  int? _loadedWidth;
  int? _requestedWidth;
  int? _layoutWidth;
  int _requestGeneration = 0;
  int _retryAttempts = 0;
  bool _syncQueued = false;
  Timer? _retryTimer;

  static const int _maxRetryAttempts = 3;

  bool get _mayLoadBanner =>
      _premiumService.status == EntitlementStatus.free &&
      _adsService.adsAvailable;

  @override
  void initState() {
    super.initState();
    _adsService.addListener(_onStateChanged);
    _premiumService.addListener(_onStateChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncForEntitlement();
    });
  }

  @override
  void dispose() {
    _adsService.removeListener(_onStateChanged);
    _premiumService.removeListener(_onStateChanged);
    _requestGeneration++;
    _retryTimer?.cancel();
    _disposeBanner();
    super.dispose();
  }

  void _onStateChanged() {
    _syncForEntitlement();
  }

  void _syncForEntitlement() {
    if (_premiumService.status != EntitlementStatus.free) {
      _requestGeneration++;
      _requestedWidth = null;
      _cancelRetry(resetAttempts: true);
      _disposeBanner(updateUi: true);
      return;
    }

    unawaited(_adsService.initialize());
    if (!_adsService.adsAvailable) {
      _requestGeneration++;
      _requestedWidth = null;
      _disposeBanner(updateUi: true);
      if (!_adsService.isInitializing && _adsService.lastError != null) {
        _scheduleRetry();
      }
      return;
    }
    _queueSync();
  }

  void _queueSync([int? width]) {
    if (width != null && width > 0) {
      _layoutWidth = width;
    }
    if (_syncQueued || !mounted) return;
    _syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncQueued = false;
      if (!mounted) return;
      final targetWidth = _layoutWidth ?? _availableWidth(context);
      if (targetWidth > 0) {
        unawaited(_loadBanner(targetWidth));
      }
    });
  }

  int _availableWidth(BuildContext context) {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (mediaQuery == null) return 0;
    return (mediaQuery.size.width - mediaQuery.padding.horizontal)
        .floor()
        .clamp(0, 10000);
  }

  Future<void> _loadBanner(int width) async {
    if (!_mayLoadBanner ||
        width <= 0 ||
        _loadedWidth == width ||
        _requestedWidth == width) {
      return;
    }

    final adUnitId = MonetizationConfig.bannerAdUnitId;
    if (adUnitId == null) return;

    final generation = ++_requestGeneration;
    _requestedWidth = width;
    _retryTimer?.cancel();
    _retryTimer = null;
    _disposeBanner(updateUi: true);

    final size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width);
    if (!mounted || generation != _requestGeneration || !_mayLoadBanner) {
      if (generation == _requestGeneration) _requestedWidth = null;
      return;
    }
    if (size == null) {
      _requestedWidth = null;
      return;
    }

    late final BannerAd banner;
    banner = BannerAd(
      adUnitId: adUnitId,
      request: const AdRequest(),
      size: size,
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (identical(_loadingBanner, banner)) {
            _loadingBanner = null;
          }
          if (!mounted || generation != _requestGeneration || !_mayLoadBanner) {
            ad.dispose();
            return;
          }
          setState(() {
            _banner = banner;
            _loadedWidth = width;
            _requestedWidth = null;
            _retryAttempts = 0;
          });
        },
        onAdFailedToLoad: (ad, error) {
          if (identical(_loadingBanner, banner)) {
            _loadingBanner = null;
          }
          ad.dispose();
          if (!mounted || generation != _requestGeneration) return;
          _requestedWidth = null;
          _disposeBanner(updateUi: true);
          _scheduleRetry();
          debugPrint('Banner ad failed to load: $error');
        },
      ),
    );
    _loadingBanner = banner;
    unawaited(banner.load());
  }

  void _scheduleRetry() {
    if (!mounted ||
        _premiumService.status != EntitlementStatus.free ||
        _retryTimer?.isActive == true ||
        _retryAttempts >= _maxRetryAttempts) {
      return;
    }

    final delaySeconds = 15 * (1 << _retryAttempts);
    _retryAttempts++;
    _retryTimer = Timer(Duration(seconds: delaySeconds), () {
      _retryTimer = null;
      if (!mounted || _premiumService.status != EntitlementStatus.free) {
        return;
      }
      if (!_adsService.adsAvailable && _adsService.lastError != null) {
        unawaited(_adsService.retryInitialization());
      } else {
        _queueSync();
      }
    });
  }

  void _cancelRetry({required bool resetAttempts}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (resetAttempts) _retryAttempts = 0;
  }

  void _disposeBanner({bool updateUi = false}) {
    final banner = _banner;
    final loadingBanner = _loadingBanner;
    _banner = null;
    _loadingBanner = null;
    _loadedWidth = null;
    banner?.dispose();
    loadingBanner?.dispose();

    if (updateUi && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final constrainedWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth.floor().clamp(0, 10000)
            : _availableWidth(context);
        _queueSync(constrainedWidth);

        final banner = _banner;
        if (!_mayLoadBanner || banner == null) {
          return const SizedBox.shrink();
        }

        return SafeArea(
          top: false,
          child: SizedBox(
            width: banner.size.width.toDouble(),
            height: banner.size.height.toDouble(),
            child: AdWidget(ad: banner),
          ),
        );
      },
    );
  }
}
