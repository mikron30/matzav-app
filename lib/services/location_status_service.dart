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
  bool _awayEnabled = true;
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
    _awayEnabled = featureSettings.away;

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
      final activeParts = <String>[
        if (_drivingEnabled) 'נהיגה',
        if (_zonesEnabled) 'אזורים',
        if (_awayEnabled) 'בית/לא בבית',
      ];
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Matzav – זיהוי מיקום פעיל',
          notificationText:
              'זיהוי פעיל: ${activeParts.join(' + ')}. Matzav משתמשת ב־GPS לעדכון הסטטוס.',
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
        final locationActivity = meetingTimerActive
            ? null
            : await _activityForLocation(uid, position);
        final nextActivity = meetingTimerActive
            ? ActivityStatus.meeting
            : (locationActivity ?? fallback);
        _lastNonDriving = nextActivity;
        await UserRepository.instance.updateStatus(
          uid: uid,
          activity: nextActivity,
        );
        return;
      }

      // Avoid a short "not home" flash while two medium-speed samples are
      // accumulating and the device is about to enter driving mode.
      if (!_driving && speed >= 5.5) return;
    } else {
      _fastSamples = 0;
      _slowSamples = 0;
      _driving = false;
    }

    if (_driving || (!_zonesEnabled && !_awayEnabled)) return;

    // A manually selected meeting with a timer temporarily takes priority over
    // all GPS-derived statuses.
    if (await StatusTimerService.instance.isMeetingTimerActive()) return;

    final fallback = await StatusTimerService.instance.resolveActivityReturn(
      uid,
      _lastNonDriving,
    );
    if (fallback != _lastNonDriving) {
      _lastNonDriving = fallback;
    }

    final locationActivity = await _activityForLocation(uid, position);
    if (locationActivity != null && locationActivity != _lastNonDriving) {
      _lastNonDriving = locationActivity;
      await UserRepository.instance.updateStatus(
        uid: uid,
        activity: locationActivity,
      );
    }
  }

  Future<ActivityStatus?> _activityForLocation(
    String uid,
    Position position,
  ) async {
    final zones = await UserRepository.instance.getZones(uid);

    // Always know whether home is configured when "not home" detection is on.
    // Without a saved home location we cannot safely conclude that the user is
    // away, so the detector does nothing until home has been saved.
    final home = _readZone(zones['home']);
    final isHome = home != null && _inside(position, home);

    if (_zonesEnabled) {
      // Home wins if zones overlap. Other configured locations then provide a
      // more useful status than the generic "not home" value.
      if (isHome) return ActivityStatus.home;

      final work = _readZone(zones['work']);
      if (work != null && _inside(position, work)) {
        return ActivityStatus.work;
      }

      final hobby = _readZone(zones['hobby']);
      if (hobby != null && _inside(position, hobby)) {
        return ActivityStatus.hobby;
      }

      final dogWalk = _readZone(zones['dogWalk']);
      if (dogWalk != null && _inside(position, dogWalk)) {
        return ActivityStatus.dogWalk;
      }
    } else if (_awayEnabled && isHome) {
      // "Not home" can operate independently from the other named zones.
      return ActivityStatus.home;
    }

    if (_awayEnabled && home != null && !isHome) {
      return ActivityStatus.away;
    }

    return null;
  }

  _SavedZone? _readZone(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final lat = (map['lat'] as num?)?.toDouble();
    final lng = (map['lng'] as num?)?.toDouble();
    final radius = (map['radius'] as num?)?.toDouble() ?? 150;
    if (lat == null || lng == null) return null;
    return _SavedZone(lat: lat, lng: lng, radius: radius);
  }

  bool _inside(Position position, _SavedZone zone) {
    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      zone.lat,
      zone.lng,
    );
    return distance <= zone.radius;
  }
}

class _SavedZone {
  const _SavedZone({
    required this.lat,
    required this.lng,
    required this.radius,
  });

  final double lat;
  final double lng;
  final double radius;
}
