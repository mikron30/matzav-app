import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/monetization_config.dart';

/// Coordinates UMP consent and Mobile Ads initialization once per app launch.
class AdsService extends ChangeNotifier {
  AdsService._();

  static final AdsService instance = AdsService._();

  Future<void>? _initialization;
  bool _isInitializing = false;
  bool _canRequestAds = false;
  bool _isSdkInitialized = false;
  bool _privacyOptionsRequired = false;
  String? _lastError;

  bool get isInitializing => _isInitializing;
  bool get canRequestAds => _canRequestAds;
  bool get isSdkInitialized => _isSdkInitialized;
  bool get privacyOptionsRequired => _privacyOptionsRequired;
  String? get lastError => _lastError;

  /// Whether a banner may be requested right now.
  bool get adsAvailable =>
      MonetizationConfig.hasBannerAdUnitId &&
      _canRequestAds &&
      _isSdkInitialized;

  /// Updates consent on every process launch and initializes ads only when
  /// both consent and a usable ad unit ID are available.
  Future<void> initialize() {
    final existingInitialization = _initialization;
    if (existingInitialization != null) {
      return existingInitialization;
    }

    // Schedule the body after caching the Future so listener callbacks cannot
    // re-enter initialization during its first synchronous notification.
    final initialization = Future<void>.microtask(_initialize);
    _initialization = initialization;
    return initialization;
  }

  /// Retries consent/SDK setup after a transient startup failure.
  Future<void> retryInitialization() {
    if (_isInitializing) {
      return _initialization ?? Future<void>.value();
    }
    _initialization = null;
    return initialize();
  }

  Future<void> _initialize() async {
    if (!MonetizationConfig.isSupportedPlatform ||
        !MonetizationConfig.hasBannerAdUnitId) {
      return;
    }

    _isInitializing = true;
    _lastError = null;
    notifyListeners();

    try {
      final updateError = await _requestConsentInfoUpdate();
      if (updateError == null) {
        final formError = await _loadAndShowConsentFormIfRequired();
        if (formError != null) {
          _lastError = _describeFormError(formError);
        }
      } else {
        _lastError = _describeFormError(updateError);
      }

      await _refreshConsentState();
      await _initializeSdkIfAllowed();
    } catch (error) {
      _lastError = error.toString();
      _canRequestAds = false;
      debugPrint('Ads consent initialization failed: $error');
    } finally {
      _isInitializing = false;
      notifyListeners();
    }
  }

  Future<FormError?> _requestConsentInfoUpdate() {
    final completer = Completer<FormError?>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () => completer.complete(),
      completer.complete,
    );
    return completer.future;
  }

  Future<FormError?> _loadAndShowConsentFormIfRequired() async {
    FormError? result;
    await ConsentForm.loadAndShowConsentFormIfRequired((formError) {
      result = formError;
    });
    return result;
  }

  Future<void> _refreshConsentState() async {
    _canRequestAds = await ConsentInformation.instance.canRequestAds();
    final privacyStatus = await ConsentInformation.instance
        .getPrivacyOptionsRequirementStatus();
    _privacyOptionsRequired =
        privacyStatus == PrivacyOptionsRequirementStatus.required;
    notifyListeners();
  }

  Future<void> _initializeSdkIfAllowed() async {
    if (!_canRequestAds ||
        _isSdkInitialized ||
        !MonetizationConfig.hasBannerAdUnitId) {
      return;
    }

    await MobileAds.instance.initialize();
    _isSdkInitialized = true;
    notifyListeners();
  }

  /// Presents the UMP privacy choices form when Google requires an entry point.
  ///
  /// Returns a form error, if any. Unsupported platforms safely return `null`.
  Future<FormError?> showPrivacyOptionsForm() async {
    if (!MonetizationConfig.isSupportedPlatform || !_privacyOptionsRequired) {
      return null;
    }

    FormError? formError;
    await ConsentForm.showPrivacyOptionsForm((result) {
      formError = result;
    });

    final resolvedFormError = formError;
    if (resolvedFormError == null) {
      _lastError = null;
    } else {
      _lastError = _describeFormError(resolvedFormError);
    }

    try {
      await _refreshConsentState();
      await _initializeSdkIfAllowed();
    } catch (error) {
      _lastError = error.toString();
      debugPrint('Could not refresh ads consent state: $error');
    }
    notifyListeners();
    return resolvedFormError;
  }

  String _describeFormError(FormError error) =>
      'Consent error ${error.errorCode}: ${error.message}';
}
