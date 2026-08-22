import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The entitlement is deliberately unknown until the local cache is loaded.
/// Callers must only unlock premium behavior for [EntitlementStatus.premium].
enum EntitlementStatus { unknown, free, premium }

/// Owns the lifetime of the store purchase stream and the premium entitlement.
///
/// Create/access this service and call [initialize] as early as possible during
/// application startup. The purchase stream subscription is installed
/// synchronously in the constructor, before any store or preferences work.
class PremiumService extends ChangeNotifier {
  PremiumService({
    InAppPurchase? inAppPurchase,
    SharedPreferencesAsync? preferences,
  }) : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance,
       _preferences = preferences ?? SharedPreferencesAsync() {
    _purchaseSubscription = _inAppPurchase.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: _handlePurchaseStreamError,
    );
  }

  static const String productId = 'matzav_premium';
  static const String _entitlementCacheKey =
      'premium_entitlement_matzav_premium_v1';

  static final PremiumService instance = PremiumService();

  final InAppPurchase _inAppPurchase;
  final SharedPreferencesAsync _preferences;
  late final StreamSubscription<List<PurchaseDetails>> _purchaseSubscription;

  EntitlementStatus _entitlementStatus = EntitlementStatus.unknown;
  ProductDetails? _productDetails;
  bool _storeAvailable = false;
  bool _isLoading = false;
  bool _isPurchasePending = false;
  bool _isRestoring = false;
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _automaticRestoreAttempted = false;
  bool _awaitingRestoreResult = false;
  String? _errorMessage;
  String? _applicationUserName;
  Future<void>? _initialization;

  EntitlementStatus get status => _entitlementStatus;
  EntitlementStatus get entitlementStatus => _entitlementStatus;
  bool get isPremium => _entitlementStatus == EntitlementStatus.premium;
  bool get storeAvailable => _storeAvailable;
  bool get isLoading => _isLoading;
  bool get isPending => _isPurchasePending;
  bool get isRestoring => _isRestoring;
  bool get isInitialized => _isInitialized;
  bool get productAvailable => _productDetails != null;
  String? get price => _productDetails?.price;
  String? get errorMessage => _errorMessage;

  /// Returns an opaque, stable value suitable for PurchaseParam's
  /// applicationUserName. A raw Firebase UID must never be sent to the store.
  static String hashUid(String uid) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      throw ArgumentError.value(uid, 'uid', 'UID must not be empty.');
    }
    return sha256.convert(utf8.encode(normalizedUid)).toString();
  }

  /// Loads the cached entitlement and product information.
  ///
  /// Supply either a raw [uid], which is SHA-256 hashed here, or an already
  /// opaque [hashedUid]. Supplying neither is supported for restore flows that
  /// previously made a purchase without applicationUserName.
  Future<void> initialize({String? uid, String? hashedUid}) {
    _configureApplicationUserName(uid: uid, hashedUid: hashedUid);
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    _isLoading = true;
    _notifyListeners();

    try {
      final cachedPremium =
          await _preferences.getBool(_entitlementCacheKey) ?? false;
      // A purchase update may have granted premium while preferences loaded.
      if (_entitlementStatus != EntitlementStatus.premium) {
        _entitlementStatus = cachedPremium
            ? EntitlementStatus.premium
            : EntitlementStatus.unknown;
      }
    } catch (error) {
      _errorMessage = 'לא ניתן היה לקרוא את סטטוס הפרימיום: $error';
    } finally {
      _isInitialized = true;
      _isLoading = false;
      _notifyListeners();
    }

    await refreshStore();
    // Keep ads disabled while an Android restore result is still on its way.
    // If the store cannot perform that check, use the free entitlement so the
    // rest of the app remains usable offline.
    if (_entitlementStatus == EntitlementStatus.unknown &&
        !_awaitingRestoreResult) {
      await _setFreeEntitlement();
      _notifyListeners();
    }
  }

  /// Rechecks store availability and loads the localized product and price.
  Future<void> refreshStore() async {
    _isLoading = true;
    _errorMessage = null;
    _notifyListeners();

    try {
      _storeAvailable = await _inAppPurchase.isAvailable();
      if (!_storeAvailable) {
        _productDetails = null;
        return;
      }

      final response = await _inAppPurchase.queryProductDetails(<String>{
        productId,
      });
      if (response.error != null) {
        _errorMessage = response.error!.message;
      }

      _productDetails = null;
      for (final product in response.productDetails) {
        if (product.id == productId) {
          _productDetails = product;
          break;
        }
      }

      if (_productDetails == null && _errorMessage == null) {
        _errorMessage = response.notFoundIDs.contains(productId)
            ? 'מוצר הפרימיום עדיין אינו זמין בחנות.'
            : 'לא ניתן לטעון את מוצר הפרימיום.';
      }
    } catch (error) {
      _storeAvailable = false;
      _productDetails = null;
      _errorMessage = 'לא ניתן להתחבר לחנות: $error';
    } finally {
      _isLoading = false;
      _notifyListeners();
    }

    if (_storeAvailable &&
        _productDetails != null &&
        defaultTargetPlatform == TargetPlatform.android &&
        !_automaticRestoreAttempted) {
      _automaticRestoreAttempted = true;
      await restorePurchases();
    }
  }

  /// Starts the permanent, non-consumable premium purchase.
  ///
  /// [uid] is hashed before it reaches the store. [hashedUid] is accepted for
  /// callers that already hold an opaque SHA-256 user identifier.
  Future<bool> buyPremium({String? uid, String? hashedUid}) async {
    _configureApplicationUserName(uid: uid, hashedUid: hashedUid);

    if (isPremium || _isPurchasePending || _isRestoring) return false;
    final product = _productDetails;
    if (!_storeAvailable || product == null) {
      _errorMessage = 'מוצר הפרימיום אינו זמין כרגע.';
      _notifyListeners();
      return false;
    }

    _errorMessage = null;
    _isPurchasePending = true;
    _notifyListeners();

    try {
      final accepted = await _inAppPurchase.buyNonConsumable(
        purchaseParam: PurchaseParam(
          productDetails: product,
          applicationUserName: _applicationUserName,
        ),
      );
      if (!accepted) {
        _isPurchasePending = false;
        _errorMessage = 'החנות לא הצליחה להתחיל את הרכישה.';
        _notifyListeners();
      }
      return accepted;
    } catch (error) {
      _isPurchasePending = false;
      _errorMessage = 'לא ניתן להתחיל את הרכישה: $error';
      _notifyListeners();
      return false;
    }
  }

  /// Requests restoration of this permanent purchase from the store.
  Future<void> restorePurchases({String? uid, String? hashedUid}) async {
    _configureApplicationUserName(uid: uid, hashedUid: hashedUid);
    if (_isRestoring || _isPurchasePending) return;

    _isRestoring = true;
    _awaitingRestoreResult = true;
    _errorMessage = null;
    _notifyListeners();
    try {
      await _inAppPurchase.restorePurchases(
        applicationUserName: _applicationUserName,
      );
    } catch (error) {
      _awaitingRestoreResult = false;
      _errorMessage = 'לא ניתן לשחזר רכישות: $error';
    } finally {
      _isRestoring = false;
      _notifyListeners();
    }
  }

  void clearError() {
    if (_errorMessage == null) return;
    _errorMessage = null;
    _notifyListeners();
  }

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    final premiumPurchases = purchases
        .where((purchase) => purchase.productID == productId)
        .toList(growable: false);
    if (premiumPurchases.isEmpty) {
      if (_awaitingRestoreResult) {
        _awaitingRestoreResult = false;
        await _setFreeEntitlement();
        _notifyListeners();
      }
      return;
    }
    _awaitingRestoreResult = false;

    var hasPendingPurchase = false;
    for (final purchase in premiumPurchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          // Pending is never an entitlement. Wait for a later purchased or
          // restored event before granting premium.
          hasPendingPurchase = true;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          final verified = _verifyPurchaseForMvp(purchase);
          if (verified) {
            _errorMessage = null;
            await _grantPremium();
            if (purchase.pendingCompletePurchase) {
              try {
                await _inAppPurchase.completePurchase(purchase);
              } catch (error) {
                _errorMessage =
                    'הרכישה התקבלה אך לא ניתן היה להשלים אותה: $error';
              }
            }
          } else {
            _errorMessage = 'לא ניתן לאמת את רכישת הפרימיום.';
          }
        case PurchaseStatus.error:
          _errorMessage =
              purchase.error?.message ?? 'אירעה שגיאה במהלך הרכישה.';
        case PurchaseStatus.canceled:
          // Cancellation is not an error and, critically, is not premium.
          _errorMessage = null;
      }
    }

    _isPurchasePending = hasPendingPurchase;
    _notifyListeners();
  }

  /// MVP-only local verification.
  ///
  /// Production must send serverVerificationData to a trusted backend and
  /// verify it with Google Play/App Store before granting the entitlement.
  /// Client-side checks and SharedPreferences can be modified by an attacker.
  bool _verifyPurchaseForMvp(PurchaseDetails purchase) {
    return purchase.productID == productId &&
        purchase.verificationData.serverVerificationData.isNotEmpty;
  }

  Future<void> _grantPremium() async {
    _entitlementStatus = EntitlementStatus.premium;
    try {
      await _preferences.setBool(_entitlementCacheKey, true);
    } catch (error) {
      _errorMessage =
          'הפרימיום הופעל, אך לא ניתן היה לשמור אותו במכשיר: $error';
    }
  }

  Future<void> _setFreeEntitlement() async {
    _entitlementStatus = EntitlementStatus.free;
    try {
      await _preferences.setBool(_entitlementCacheKey, false);
    } catch (error) {
      _errorMessage = 'לא ניתן היה לעדכן את סטטוס הפרימיום: $error';
    }
  }

  void _configureApplicationUserName({String? uid, String? hashedUid}) {
    final hasUid = uid != null && uid.trim().isNotEmpty;
    final hasHashedUid = hashedUid != null && hashedUid.trim().isNotEmpty;
    if (hasUid && hasHashedUid) {
      throw ArgumentError('Supply uid or hashedUid, not both.');
    }
    if (hasUid) {
      _applicationUserName = hashUid(uid);
    } else if (hasHashedUid) {
      _applicationUserName = hashedUid.trim();
    }
  }

  void _handlePurchaseStreamError(Object error, StackTrace stackTrace) {
    _isPurchasePending = false;
    _errorMessage = 'לא ניתן לקבל עדכון רכישה מהחנות: $error';
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_purchaseSubscription.cancel());
    super.dispose();
  }
}
