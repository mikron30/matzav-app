import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/status_models.dart';
import 'automation_preferences.dart';
import 'automatic_status_service.dart';
import 'status_timer_service.dart';
import 'user_repository.dart';

class LocationStatusService {
  LocationStatusService._();
  static final instance = LocationStatusService._();

  StreamSubscription<Position>? _subscription;
  String? _uid;
  int _fastSamples = 0;
  int _slowSamples = 0;
  bool _driving = false;
  bool _drivingEnabled = true;
  bool _zonesEnabled = true;
  ActivityStatus _lastNonDriving = ActivityStatus.home;

  bool get running => _subscription != null;

  Future<bool> isAutomationEnabled() async {
    final settings = await AutomationPreferences.instance.load();
    return settings.anyEnabled;
  }

  void noteManualActivity(ActivityStatus activity) {
    if (activity != ActivityStatus.driving) {
      _lastNonDriving = activity;
    }
  }

  Future<void> start({
    required String uid,
    required ActivityStatus currentActivity,
    bool remember = true,
  }) async {
    final featureSettings = await AutomationPreferences.instance.load();
    _drivingEnabled = featureSettings.driving;
    _zonesEnabled = featureSettings.zones;

    if (!featureSettings.locationEnabled) {
      await stop();
      return;
    }

    if (_subscription != null) {
      _uid = uid;
      return;
    }

    _uid = uid;
    _driving = _drivingEnabled && currentActivity == ActivityStatus.driving;
    if (currentActivity != ActivityStatus.driving) {
      _lastNonDriving = currentActivity;
    }

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) throw Exception('שירותי המיקום כבויים');

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('אין הרשאת מיקום');
    }

    final LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final title = _drivingEnabled && _zonesEnabled
          ? 'Matzav – זיהוי מיקום פעיל'
          : _drivingEnabled
          ? 'Matzav – זיהוי נסיעה פעיל'
          : 'Matzav – זיהוי אזורים פעיל';
      final text = _drivingEnabled && _zonesEnabled
          ? 'Matzav משתמשת במיקום כדי לזהות נסיעה ואזורים שהוגדרו.'
          : _drivingEnabled
          ? 'Matzav בודקת מהירות כדי לעדכן אוטומטית את הסטטוס.'
          : 'Matzav בודקת אם נכנסת לאזור בית/עבודה/כלב שהוגדר.';

      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: title,
          notificationText: text,
          notificationChannelName: 'זיהוי מיקום אוטומטי',
          setOngoing: true,
          enableWakeLock: false,
          enableWifiLock: false,
        ),
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
    }

    _fastSamples = 0;
    _slowSamples = 0;
    _subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen(
          _handlePosition,
          onError: (_) {
            _subscription?.cancel();
            _subscription = null;
          },
        );
  }

  Future<void> refresh({
    required String uid,
    required ActivityStatus currentActivity,
  }) async {
    final featureSettings = await AutomationPreferences.instance.load();
    var activityForRestart = currentActivity;

    // If driving was the automatic temporary state and the user switches that
    // detector off, do not leave the public profile stuck on "driving".
    if (!featureSettings.driving && currentActivity == ActivityStatus.driving) {
      activityForRestart = await StatusTimerService.instance.resolveActivityReturn(
        uid,
        _lastNonDriving,
      );
      await UserRepository.instance.updateStatus(
        uid: uid,
        activity: activityForRestart,
      );
    }

    await stop();
    await start(
      uid: uid,
      currentActivity: activityForRestart,
      remember: false,
    );
  }

  Future<void> stop({bool rememberOff = false}) async {
    await _subscription?.cancel();
    _subscription = null;
    _uid = null;
    _fastSamples = 0;
    _slowSamples = 0;
    _driving = false;
  }

  Future<void> disable() => stop(rememberOff: true);

  Future<void> _handlePosition(Position position) async {
    final uid = _uid;
    if (uid == null) return;

    // Phone-call and sleep overrides take priority over location automation.
    if (AutomaticStatusService.instance.overrideActive) return;

    final speed = position.speed;

    if (_drivingEnabled) {
      // Position.speed is meters/second.
      // >= 8.3 m/s is ~30 km/h: a single reading is enough to react quickly.
      // >= 5.5 m/s is ~20 km/h: require two consecutive readings.
      if (speed >= 8.3) {
        _fastSamples = 2;
        _slowSamples = 0;
      } else if (speed >= 5.5) {
        _fastSamples++;
        _slowSamples = 0;
      } else if (speed >= 0 && speed <= 2.0) {
        _slowSamples++;
        _fastSamples = 0;
      } else {
        _fastSamples = 0;
        _slowSamples = 0;
      }

      if (!_driving && _fastSamples >= 2) {
        _driving = true;
        await UserRepository.instance.updateStatus(
          uid: uid,
          activity: ActivityStatus.driving,
        );
        return;
      }

      // With a 5-second Android interval, three slow samples means roughly
      // 15 seconds stopped before leaving driving mode.
      if (_driving && _slowSamples >= 3) {
        _driving = false;
        final fallback = await StatusTimerService.instance.resolveActivityReturn(
          uid,
          _lastNonDriving,
        );
        final meetingTimerActive = await StatusTimerService.instance
            .isMeetingTimerActive();
        final zoneActivity = meetingTimerActive || !_zonesEnabled
            ? null
            : await _activityForZone(uid, position);
        final nextActivity = meetingTimerActive
            ? ActivityStatus.meeting
            : (zoneActivity ?? fallback);
        _lastNonDriving = nextActivity;
        await UserRepository.instance.updateStatus(
          uid: uid,
          activity: nextActivity,
        );
        return;
      }
    } else {
      _fastSamples = 0;
      _slowSamples = 0;
      _driving = false;
    }

    if (_zonesEnabled && !_driving && speed >= 0 && speed <= 2.0) {
      // A manually selected meeting with a timer temporarily takes priority
      // over home/work/dog-walk zones. "לא בבית" remains manual-only.
      if (await StatusTimerService.instance.isMeetingTimerActive()) return;

      final fallback = await StatusTimerService.instance.resolveActivityReturn(
        uid,
        _lastNonDriving,
      );
      if (fallback != _lastNonDriving) {
        _lastNonDriving = fallback;
      }

      final zoneActivity = await _activityForZone(uid, position);
      if (zoneActivity != null && zoneActivity != _lastNonDriving) {
        _lastNonDriving = zoneActivity;
        await UserRepository.instance.updateStatus(
          uid: uid,
          activity: zoneActivity,
        );
      }
    }
  }

  Future<ActivityStatus?> _activityForZone(
    String uid,
    Position position,
  ) async {
    if (!_zonesEnabled) return null;
    return (await _zoneResult(uid, position)).activity;
  }

  Future<_ZoneResult> _zoneResult(String uid, Position position) async {
    final zones = await UserRepository.instance.getZones(uid);
    for (final entry in zones.entries) {
      if (entry.value is! Map) continue;
      final map = Map<String, dynamic>.from(entry.value as Map);
      final lat = (map['lat'] as num?)?.toDouble();
      final lng = (map['lng'] as num?)?.toDouble();
      final radius = (map['radius'] as num?)?.toDouble() ?? 150;
      if (lat == null || lng == null) continue;

      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        lat,
        lng,
      );
      if (distance <= radius) {
        switch (entry.key) {
          case 'home':
            return const _ZoneResult(activity: ActivityStatus.home);
          case 'work':
            return const _ZoneResult(activity: ActivityStatus.work);
          case 'dogWalk':
            return const _ZoneResult(activity: ActivityStatus.dogWalk);
        }
      }
    }

    return const _ZoneResult(activity: null);
  }
}

class _ZoneResult {
  const _ZoneResult({required this.activity});

  final ActivityStatus? activity;
}
