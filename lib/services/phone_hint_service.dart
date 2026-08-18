import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PhoneHintService {
  PhoneHintService._();
  static final instance = PhoneHintService._();

  static const MethodChannel _channel =
      MethodChannel('com.mikron30.matzav/phone_hint');

  Future<String?> requestPhoneNumberHint() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    try {
      final phone =
          await _channel.invokeMethod<String>('requestPhoneNumberHint');
      final trimmed = phone?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    } on PlatformException {
      // If the device/SIM cannot provide a hint, the Flutter UI falls back
      // to manual phone-number entry.
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
