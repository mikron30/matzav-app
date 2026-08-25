import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_models.dart';
import 'status_timer_service.dart';
import 'user_repository.dart';

/// Coordinates Android automatic overrides that take priority over location:
/// an active audio/phone conversation and nighttime sleep detection.
///
/// The native side only reads Android's current audio mode and interactive
/// screen state. It does not read call audio, caller identity, call logs, or
/// message content.
class AutomaticStatusService {
  AutomaticStatusService._();
  static final instance = AutomaticStatusService._();

  static const MethodChannel _channel = MethodChannel(
    'com.mikron30.matzav/automatic_status',
  );

  static const _previousActivityKey = 'automatic_status_previous_activity_v1';
  static const _lastOverrideKey = 'automatic_status_last_override_v1';

  String? _uid;
  String _currentOverride = 'none';
  bool _handlerInstalled = false;

  bool get overrideActive => _currentOverride != 'none';

  Future<void> _ensureHandler() async {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'statusOverrideChanged') return;
      final activity =
          (call.arguments as Map?)?['activity']?.toString() ?? 'none';
      await _applyOverride(activity);
    });
  }

  Future<void> start({required String uid}) async {
    _uid = uid;
    await _ensureHandler();

    try {
      await _channel.invokeMethod<void>('startMonitoring');
      final current =
          await _channel.invokeMethod<String>('getCurrentOverride') ?? 'none';
      await _applyOverride(current);
    } on MissingPluginException {
      // Android-only feature.
    } on PlatformException {
      // The other automatic mechanisms continue to work even if native
      // monitoring is unavailable on a particular device.
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stopMonitoring');
    } on MissingPluginException {
      // Android-only feature.
    } on PlatformException {
      // We still restore the previous status below.
    }
    await _applyOverride('none');
    _uid = null;
  }

  Future<void> _applyOverride(String next) async {
    final uid = _uid;
    if (uid == null) {
      _currentOverride = next;
      return;
    }

    final normalized =
        next == ActivityStatus.onCall.name ||
                next == ActivityStatus.sleeping.name
            ? next
            : 'none';

    final prefs = await SharedPreferences.getInstance();
    final previousOverride =
        prefs.getString(_lastOverrideKey) ?? _currentOverride;

    if (normalized == previousOverride) {
      _currentOverride = normalized;
      return;
    }

    if (normalized != 'none') {
      // Save the real status only when entering the first temporary override.
      // A transition "sleeping -> onCall" must keep the status from before
      // sleeping, not replace it with another temporary status.
      if (previousOverride == 'none') {
        final snapshot = await UserRepository.instance.profileStream(uid).first;
        final current = activityFromString(
          snapshot.data()?['activity'] as String?,
        );
        if (current != ActivityStatus.onCall &&
            current != ActivityStatus.sleeping) {
          await prefs.setString(_previousActivityKey, current.name);
        }
      }

      final automaticActivity = normalized == ActivityStatus.onCall.name
          ? ActivityStatus.onCall
          : ActivityStatus.sleeping;
      await UserRepository.instance.updateStatus(
        uid: uid,
        activity: automaticActivity,
      );
    } else {
      final previousName = prefs.getString(_previousActivityKey);
      var previous = activityFromString(previousName);
      previous = await StatusTimerService.instance.resolveActivityReturn(
        uid,
        previous,
      );
      await UserRepository.instance.updateStatus(
        uid: uid,
        activity: previous,
      );
      await prefs.remove(_previousActivityKey);
    }

    _currentOverride = normalized;
    await prefs.setString(_lastOverrideKey, normalized);
  }
}