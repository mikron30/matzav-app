import 'package:flutter/services.dart';

class DirectCallService {
  DirectCallService._();
  static final instance = DirectCallService._();

  static const MethodChannel _channel = MethodChannel(
    'com.mikron30.matzav/direct_call',
  );

  Future<bool> callNumber(String phone) async {
    final trimmed = phone.trim();
    if (trimmed.isEmpty) return false;

    try {
      final result = await _channel.invokeMethod<bool>('callNumber', {
        'phone': trimmed,
      });
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
