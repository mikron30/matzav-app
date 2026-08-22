import 'package:flutter/foundation.dart';

/// Compile-time configuration for Matzav's advertising features.
abstract final class MonetizationConfig {
  static const String androidBannerTestId =
      'ca-app-pub-3940256099942544/6300978111';

  static const String _androidBannerId = String.fromEnvironment(
    'MATZAV_ADMOB_ANDROID_BANNER_ID',
  );

  /// Explicitly opts a release build into Google's test banner unit.
  static const bool useTestAds = bool.fromEnvironment(
    'MATZAV_USE_TEST_ADS',
    defaultValue: false,
  );

  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// The safe banner ID for this build, or `null` when ads must stay disabled.
  ///
  /// Non-release builds always use Google's Android test unit. Release builds
  /// require a production ID unless test ads were explicitly enabled.
  static String? get androidBannerAdUnitId {
    if (!isSupportedPlatform) {
      return null;
    }

    if (!kReleaseMode || useTestAds) {
      return androidBannerTestId;
    }

    final configuredId = _androidBannerId.trim();
    if (!_adUnitIdPattern.hasMatch(configuredId) ||
        configuredId == androidBannerTestId) {
      return null;
    }
    return configuredId;
  }

  static String? get bannerAdUnitId => androidBannerAdUnitId;

  static bool get hasBannerAdUnitId => bannerAdUnitId != null;

  static final RegExp _adUnitIdPattern = RegExp(r'^ca-app-pub-\d{16}/\d{10}$');
}
