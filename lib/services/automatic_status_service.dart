import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_models.dart';
import 'automation_preferences.dart';
import 'busy_availability_service.dart';
import 'status_timer_service.dart';
import 'user_repository.dart';

/// Coordinates Android automatic overrides that take priority over location:
/// an active phone/VoIP conversation and sleep detection.
///
/// The Android side detects only aggregate call/sleep state. It does not read
/// call audio, caller identity, call logs, or message content.
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
  bool _callsEnabled = true;
  bool _sleepEnabled = true;

  bool get overrideActive => _currentOverride != 'none';

  /// Reads the current native call/sleep override before location automation
  /// decides whether it may publish a GPS-derived status. This prevents a stale
  /// Flutter-side value from permanently blocking driving/home/away detection
  /// after Android has already ended a call or sleep override in the background.
  Future<bool> isOverrideActiveNow() async {
    try {
      final current =
          await _channel.invokeMethod<String>('getCurrentOverride') ?? 'none';
      // Do not merely update the in-memory flag. If Android has already returned
      // to "none" while a previous automatic onCall/sleeping write is still in
      // Firestore, reconcile it here before location automation continues.
      await _applyOverride(current, reconcileStaleCloud: true);
    } on MissingPluginException {
      // Android-only feature. Keep the last known state on other platforms.
    } on PlatformException {
      // Keep the last known state if the native side is temporarily unavailable.
    }
    return overrideActive;
  }

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

    final settings = await AutomationPreferences.instance.load();
    _callsEnabled = settings.calls;
    _sleepEnabled = settings.sleep;

    if (!settings.nativeEnabled) {
      try {
        await _channel.invokeMethod<void>('stopMonitoring');
      } on MissingPluginException {
        // Android-only feature.
      } on PlatformException {
        // Restore below anyway.
      }
      await _applyOverride('none');
      return;
    }

    try {
      await _channel.invokeMethod<void>('startMonitoring', {
        'drivingEnabled': settings.driving,
        'callsEnabled': _callsEnabled,
        'sleepEnabled': _sleepEnabled,
      });
      final current =
          await _channel.invokeMethod<String>('getCurrentOverride') ?? 'none';
      await _applyOverride(current, reconcileStaleCloud: true);
    } on MissingPluginException {
      // Android-only feature.
    } on PlatformException {
      // The other automatic mechanisms continue to work even if native
      // monitoring is unavailable on a particular device.
    }
  }

  Future<void> refresh({required String uid}) => start(uid: uid);

  /// Android's vehicle transition remains authoritative at traffic lights.
  /// GPS remains the fallback when the detector has not observed a trip yet.
  Future<bool> isNativeDrivingActive() async {
    try {
      return await _channel.invokeMethod<bool>('isDrivingActive') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Ask Android to publish the latest persisted IN_VEHICLE state again.
  /// Used as a recovery path when a previous native Firestore transaction was
  /// delayed by temporary DNS/network failure.
  Future<void> requestNativeDrivingSync() async {
    try {
      await _channel.invokeMethod<void>('syncDrivingStatus');
    } on MissingPluginException {
      // Android-only feature.
    } on PlatformException {
      // The persisted native state remains available for a later retry.
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

  Future<void> _applyOverride(
    String next, {
    bool reconcileStaleCloud = false,
  }) async {
    final normalized = _normalizeOverride(next);
    final uid = _uid;
    if (uid == null) {
      _currentOverride = normalized;
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final previousOverride =
        prefs.getString(_lastOverrideKey) ?? _currentOverride;

    if (normalized == previousOverride) {
      _currentOverride = normalized;
      if (normalized != 'none') {
        final activity = normalized == ActivityStatus.onCall.name
            ? ActivityStatus.onCall
            : ActivityStatus.sleeping;
        await BusyAvailabilityService.instance.syncForActivity(uid, activity);
      } else if (reconcileStaleCloud) {
        await _restoreStaleCloudOverrideIfNeeded(uid, prefs);
      }
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
      await BusyAvailabilityService.instance.syncForActivity(
        uid,
        automaticActivity,
      );
    } else {
      final previous = await _resolveReturnActivity(uid, prefs);
      await UserRepository.instance.updateStatus(
        uid: uid,
        activity: previous,
      );
      await BusyAvailabilityService.instance.syncForActivity(uid, previous);
      await prefs.remove(_previousActivityKey);
    }

    _currentOverride = normalized;
    await prefs.setString(_lastOverrideKey, normalized);
    if (normalized == 'none') {
      try {
        // Reconcile only after the Flutter restoration write, as the native
        // call/sleep provider may have completed its own write earlier.
        await _channel.invokeMethod<void>('syncDrivingStatus');
      } on MissingPluginException {
        // Android-only feature.
      } on PlatformException {
        // Persisted native transitions still have their WorkManager retry.
      }
    }
  }

  String _normalizeOverride(String value) {
    return switch (value) {
      'onCall' when _callsEnabled => ActivityStatus.onCall.name,
      'sleeping' when _sleepEnabled => ActivityStatus.sleeping.name,
      _ => 'none',
    };
  }

  Future<ActivityStatus> _resolveReturnActivity(
    String uid,
    SharedPreferences prefs,
  ) async {
    final previousName = prefs.getString(_previousActivityKey);
    var previous = activityFromString(previousName);

    // A trip can start/end while a call owns the visible status. Do not restore
    // an old "driving" value after Android already detected EXIT.
    try {
      if (await isNativeDrivingActive()) {
        previous = ActivityStatus.driving;
      } else if (previous == ActivityStatus.driving) {
        final nativeReturn =
            await _channel.invokeMethod<String>('drivingReturnActivity');
        if (nativeReturn != null) previous = activityFromString(nativeReturn);
      }
    } on MissingPluginException {
      // Other platforms keep their existing restoration behavior.
    } on PlatformException {
      // Fall back to the saved status if Android is temporarily unavailable.
    }

    return StatusTimerService.instance.resolveActivityReturn(uid, previous);
  }

  Future<void> _restoreStaleCloudOverrideIfNeeded(
    String uid,
    SharedPreferences prefs,
  ) async {
    // This local marker is written only when Matzav itself entered an automatic
    // temporary override. Its presence lets us repair a stale cloud onCall/
    // sleeping state without changing a status the user selected manually.
    final previousName = prefs.getString(_previousActivityKey);
    if (previousName == null || previousName.isEmpty) return;

    final snapshot = await UserRepository.instance.profileStream(uid).first;
    final current = activityFromString(snapshot.data()?['activity'] as String?);

    if (current != ActivityStatus.onCall &&
        current != ActivityStatus.sleeping) {
      await prefs.remove(_previousActivityKey);
      return;
    }

    final previous = await _resolveReturnActivity(uid, prefs);
    await UserRepository.instance.updateStatus(
      uid: uid,
      activity: previous,
    );
    await BusyAvailabilityService.instance.syncForActivity(uid, previous);
    await prefs.remove(_previousActivityKey);
    await prefs.setString(_lastOverrideKey, 'none');
    _currentOverride = 'none';

    try {
      await _channel.invokeMethod<void>('syncDrivingStatus');
    } on MissingPluginException {
      // Android-only feature.
    } on PlatformException {
      // Persisted native transitions still have their WorkManager retry.
    }
  }
}
