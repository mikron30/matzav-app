import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/status_models.dart';
import 'automation_preferences.dart';
import 'automatic_status_service.dart';
import 'debug_log_service.dart';
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
  bool _sleepEnabled = false;
  bool _iosSleepInferred = false;
  DateTime? _iosSleepStationarySince;
  DateTime? _iosSleepStartedAt;
  Position? _iosSleepStationaryAnchor;
  ActivityStatus _lastNonDriving = ActivityStatus.home;
  DateTime? _lastDebugPositionAt;
  String? _lastDebugZoneDecision;
  DateTime? _nativeStationarySince;
  Position? _nativeStationaryAnchor;

  static const _nativeStationaryTimeout = Duration(minutes: 5);
  static const double _nativeStationarySpeedMps = 1.4; // ~5 km/h.
  static const double _nativeStationaryBaseRadiusM = 40;

  // iOS has no public API that directly exposes "the user is sleeping".
  // Infer it conservatively from the existing background location stream:
  // at home + late-night window + prolonged stationarity.
  static const _iosSleepInferenceDelay = Duration(minutes: 60);
  static const _iosSleepMaxDuration = Duration(hours: 10);
  static const double _iosSleepStationarySpeedMps = 0.8;
  static const double _iosSleepWakeSpeedMps = 1.0;
  static const double _iosSleepBaseRadiusM = 30;

  bool get _isIosPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool get running => _subscription != null;

  Future<bool> isAutomationEnabled() async {
    final settings = await AutomationPreferences.instance.load();
    return settings.anyEnabled;
  }

  void noteManualActivity(ActivityStatus activity) {
    if (_isIosPlatform &&
        _iosSleepInferred &&
        activity != ActivityStatus.sleeping) {
      _iosSleepInferred = false;
      _resetIosSleepTracking();
      unawaited(AutomaticStatusService.instance.setDerivedSleepActive(false));
    }

    if (activity != ActivityStatus.driving &&
        activity != ActivityStatus.sleeping) {
      _lastNonDriving = activity;
      _debug('manual_activity_noted', {'activity': activity.name});
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
    _sleepEnabled = _isIosPlatform && featureSettings.sleep;

    _debug('start_requested', {
      'currentActivity': currentActivity.name,
      'drivingEnabled': _drivingEnabled,
      'zonesEnabled': _zonesEnabled,
      'awayEnabled': _awayEnabled,
      'sleepEnabled': _sleepEnabled,
      'alreadyRunning': _subscription != null,
    });

    if (!featureSettings.locationEnabled && !_sleepEnabled) {
      await stop();
      _debug('start_skipped_location_features_off');
      return;
    }

    if (_subscription != null) {
      _uid = uid;
      _debug('start_reused_existing_stream');
      return;
    }

    _uid = uid;
    _driving = _drivingEnabled && currentActivity == ActivityStatus.driving;
    if (currentActivity != ActivityStatus.driving &&
        currentActivity != ActivityStatus.sleeping) {
      _lastNonDriving = currentActivity;
    }

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _debug('start_failed_location_service_off');
      throw Exception('שירותי המיקום כבויים');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        permission == LocationPermission.whileInUse) {
      // Background automation needs Always authorization. iOS may choose when
      // to show the second-stage prompt; if it remains While In Use the app
      // still works in the foreground and the user can upgrade it in Settings.
      final upgraded = await Geolocator.requestPermission();
      if (upgraded == LocationPermission.always) permission = upgraded;
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _debug('start_failed_location_permission', {'permission': permission.name});
      throw Exception('אין הרשאת מיקום');
    }
    _debug('location_permission_ok', {'permission': permission.name});

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
          enableWakeLock: true,
          enableWifiLock: false,
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      settings = const AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.other,
        distanceFilter: 10,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      );
    }

    _fastSamples = 0;
    _slowSamples = 0;
    _lastDebugPositionAt = null;
    _lastDebugZoneDecision = null;
    _resetNativeStationaryTracking();
    _resetIosSleepTracking();

    _subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen(
          _handlePosition,
          onError: (Object error) {
            _debug('position_stream_error', {'error': error.toString()});
          },
        );

    _debug('position_stream_started');
    unawaited(_evaluateCurrentPosition());
  }

  Future<void> _evaluateCurrentPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      _debug('initial_position_received', _positionData(position));
      await _handlePosition(position);
    } catch (error) {
      _debug('initial_position_failed', {'error': error.toString()});
    }
  }

  Future<void> refresh({
    required String uid,
    required ActivityStatus currentActivity,
  }) async {
    final featureSettings = await AutomationPreferences.instance.load();
    var activityForRestart = currentActivity;

    _debug('refresh', {
      'currentActivity': currentActivity.name,
      'drivingEnabled': featureSettings.driving,
      'zonesEnabled': featureSettings.zones,
      'awayEnabled': featureSettings.away,
      'sleepEnabled': _isIosPlatform && featureSettings.sleep,
    });

    if (!featureSettings.driving && currentActivity == ActivityStatus.driving) {
      activityForRestart = await StatusTimerService.instance.resolveActivityReturn(
        uid,
        _lastNonDriving,
      );
      _debug('driving_disabled_restore', {'activity': activityForRestart.name});
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
    _debug('stop', {
      'rememberOff': rememberOff,
      'wasRunning': _subscription != null,
      'wasDriving': _driving,
      'lastNonDriving': _lastNonDriving.name,
    });
    await _subscription?.cancel();
    _subscription = null;
    if (_isIosPlatform && _iosSleepInferred) {
      await AutomaticStatusService.instance.setDerivedSleepActive(false);
    }
    _uid = null;
    _fastSamples = 0;
    _slowSamples = 0;
    _driving = false;
    _iosSleepInferred = false;
    _resetNativeStationaryTracking();
    _resetIosSleepTracking();
  }

  Future<void> disable() => stop(rememberOff: true);

  Future<void> _handlePosition(Position position) async {
    final uid = _uid;
    if (uid == null) return;

    final now = DateTime.now();
    if (_lastDebugPositionAt == null ||
        now.difference(_lastDebugPositionAt!) >= const Duration(seconds: 30)) {
      _lastDebugPositionAt = now;
      _debug('position_sample', {
        ..._positionData(position),
        'drivingLocal': _driving,
        'fastSamples': _fastSamples,
        'slowSamples': _slowSamples,
        'lastNonDriving': _lastNonDriving.name,
      });
    }

    if (_sleepEnabled && _isIosPlatform) {
      final sleepActive = await _updateIosSleepInference(uid, position, now);
      if (sleepActive) return;
    }

    if (await AutomaticStatusService.instance.isOverrideActiveNow()) {
      return;
    }

    final nativeDriving = _drivingEnabled &&
        await AutomaticStatusService.instance.isNativeDrivingActive();

    if (nativeDriving) {
      // A saved home fix is stronger evidence than Activity Recognition's
      // IN_VEHICLE state. If the device is inside home, end driving immediately.
      final atHome = await _isInsideSavedHome(uid, position);
      if (atHome) {
        final meetingTimerActive =
            await StatusTimerService.instance.isMeetingTimerActive();
        final nextActivity = meetingTimerActive
            ? ActivityStatus.meeting
            : ActivityStatus.home;
        await _finishStaleNativeDriving(
          uid: uid,
          position: position,
          nextActivity: nextActivity,
          reason: 'home_override',
        );
        return;
      }

      if (_nativePositionLooksStationary(position)) {
        final anchor = _nativeStationaryAnchor;
        if (_nativeStationarySince == null || anchor == null) {
          _nativeStationarySince = now;
          _nativeStationaryAnchor = position;
          _debug('native_driving_stationary_started', {
            ..._positionData(position),
            'timeoutMinutes': _nativeStationaryTimeout.inMinutes,
          });
        } else {
          final movedM = Geolocator.distanceBetween(
            anchor.latitude,
            anchor.longitude,
            position.latitude,
            position.longitude,
          );
          final movementThresholdM = _nativeStationaryBaseRadiusM +
              anchor.accuracy +
              position.accuracy;

          if (movedM > movementThresholdM) {
            _nativeStationarySince = now;
            _nativeStationaryAnchor = position;
            _debug('native_driving_stationary_reset_movement', {
              ..._positionData(position),
              'movedM': double.parse(movedM.toStringAsFixed(1)),
              'movementThresholdM':
                  double.parse(movementThresholdM.toStringAsFixed(1)),
            });
          } else if (now.difference(_nativeStationarySince!) >=
              _nativeStationaryTimeout) {
            final nextActivity =
                await _activityAfterDrivingStops(uid, position);
            await _finishStaleNativeDriving(
              uid: uid,
              position: position,
              nextActivity: nextActivity,
              reason: 'stationary_5_minutes',
            );
            return;
          }
        }
      } else {
        if (_nativeStationarySince != null) {
          _debug('native_driving_stationary_reset_speed', {
            ..._positionData(position),
            'stationarySeconds':
                now.difference(_nativeStationarySince!).inSeconds,
          });
        }
        _resetNativeStationaryTracking();
      }

      if (!_driving) {
        _driving = true;
        _debug('native_driving_recovery_publish', _positionData(position));

        // Native detection may be correct even when its WorkManager Firestore
        // transaction is backed off because DNS/network was temporarily down.
        // Mirror the state through Flutter as well. Firestore's client cache
        // makes the local UI react immediately and keeps the write pending for
        // the next connection, while Android also gets a fresh native retry.
        unawaited(
          UserRepository.instance
              .updateStatus(uid: uid, activity: ActivityStatus.driving)
              .then(
                (_) => _debug(
                  'native_driving_recovery_publish_done',
                  _positionData(position),
                ),
              )
              .catchError(
                (Object error) => _debug(
                  'native_driving_recovery_publish_failed',
                  {'error': error.toString(), ..._positionData(position)},
                ),
              ),
        );
        unawaited(AutomaticStatusService.instance.requestNativeDrivingSync());
      }
      _fastSamples = 0;
      _slowSamples = 0;
      return;
    }

    _resetNativeStationaryTracking();

    final speed = position.speed;

    if (_drivingEnabled) {
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
        _debug('gps_enter_driving', {
          ..._positionData(position),
          'fastSamples': _fastSamples,
        });
        await UserRepository.instance.updateStatus(
          uid: uid,
          activity: ActivityStatus.driving,
        );
        return;
      }

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
        _debug('gps_exit_driving', {
          ..._positionData(position),
          'slowSamples': _slowSamples,
          'fallback': fallback.name,
          'locationActivity': locationActivity?.name,
          'nextActivity': nextActivity.name,
        });
        await UserRepository.instance.updateStatus(
          uid: uid,
          activity: nextActivity,
        );
        return;
      }

      if (!_driving && speed >= 5.5) return;
    } else {
      _fastSamples = 0;
      _slowSamples = 0;
      _driving = false;
    }

    if (_driving || (!_zonesEnabled && !_awayEnabled)) return;

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
      final previous = _lastNonDriving;
      _lastNonDriving = locationActivity;
      _debug('location_status_change', {
        ..._positionData(position),
        'from': previous.name,
        'to': locationActivity.name,
      });
      await UserRepository.instance.updateStatus(
        uid: uid,
        activity: locationActivity,
      );
    }
  }

  Future<bool> _updateIosSleepInference(
    String uid,
    Position position,
    DateTime now,
  ) async {
    final atHome = await _isInsideSavedHome(uid, position);
    final speed = position.speed < 0 ? 0.0 : position.speed;

    final canStartTonight = now.hour >= 22 || now.hour < 4;
    final insideActiveSleepWindow = now.hour >= 21 || now.hour < 11;

    if (_iosSleepInferred) {
      final exceededMaxDuration = _iosSleepStartedAt != null &&
          now.difference(_iosSleepStartedAt!) >= _iosSleepMaxDuration;
      final shouldWake = !atHome ||
          !insideActiveSleepWindow ||
          exceededMaxDuration ||
          speed > _iosSleepWakeSpeedMps;

      if (shouldWake) {
        _debug('ios_sleep_exit', {
          ..._positionData(position),
          'atHome': atHome,
          'insideSleepWindow': insideActiveSleepWindow,
          'exceededMaxDuration': exceededMaxDuration,
        });
        _iosSleepInferred = false;
        _resetIosSleepTracking();
        await AutomaticStatusService.instance.setDerivedSleepActive(false);
        return false;
      }
      return true;
    }

    if (!atHome || !canStartTonight || speed > _iosSleepStationarySpeedMps) {
      _resetIosSleepTracking();
      return false;
    }

    final anchor = _iosSleepStationaryAnchor;
    if (_iosSleepStationarySince == null || anchor == null) {
      _iosSleepStationarySince = now;
      _iosSleepStationaryAnchor = position;
      _debug('ios_sleep_stationary_started', {
        ..._positionData(position),
        'delayMinutes': _iosSleepInferenceDelay.inMinutes,
      });
      return false;
    }

    final movedM = Geolocator.distanceBetween(
      anchor.latitude,
      anchor.longitude,
      position.latitude,
      position.longitude,
    );
    final movementThresholdM = _iosSleepBaseRadiusM +
        anchor.accuracy +
        position.accuracy;

    if (movedM > movementThresholdM) {
      _iosSleepStationarySince = now;
      _iosSleepStationaryAnchor = position;
      _debug('ios_sleep_stationary_reset', {
        ..._positionData(position),
        'movedM': double.parse(movedM.toStringAsFixed(1)),
        'movementThresholdM': double.parse(
          movementThresholdM.toStringAsFixed(1),
        ),
      });
      return false;
    }

    if (now.difference(_iosSleepStationarySince!) <
        _iosSleepInferenceDelay) {
      return false;
    }

    _iosSleepInferred = true;
    _iosSleepStartedAt = now;
    _debug('ios_sleep_enter', {
      ..._positionData(position),
      'stationaryMinutes':
          now.difference(_iosSleepStationarySince!).inMinutes,
    });
    await AutomaticStatusService.instance.setDerivedSleepActive(true);
    return true;
  }

  void _resetIosSleepTracking() {
    _iosSleepStationarySince = null;
    _iosSleepStationaryAnchor = null;
    if (!_iosSleepInferred) {
      _iosSleepStartedAt = null;
    }
  }

  bool _nativePositionLooksStationary(Position position) {
    final speed = position.speed < 0 ? 0.0 : position.speed;
    return speed <= _nativeStationarySpeedMps;
  }

  void _resetNativeStationaryTracking() {
    _nativeStationarySince = null;
    _nativeStationaryAnchor = null;
  }

  Future<bool> _isInsideSavedHome(String uid, Position position) async {
    final zones = await UserRepository.instance.getZones(uid);
    final home = _readZone(zones['home']);
    return home != null && _inside(position, home);
  }

  Future<ActivityStatus> _activityAfterDrivingStops(
    String uid,
    Position position,
  ) async {
    if (await StatusTimerService.instance.isMeetingTimerActive()) {
      return ActivityStatus.meeting;
    }

    final locationActivity = await _activityForLocation(uid, position);
    if (locationActivity != null) return locationActivity;

    return StatusTimerService.instance.resolveActivityReturn(
      uid,
      _lastNonDriving,
    );
  }

  Future<void> _finishStaleNativeDriving({
    required String uid,
    required Position position,
    required ActivityStatus nextActivity,
    required String reason,
  }) async {
    final stationarySeconds = _nativeStationarySince == null
        ? null
        : DateTime.now().difference(_nativeStationarySince!).inSeconds;

    _debug('native_driving_forced_exit', {
      ..._positionData(position),
      'reason': reason,
      'stationarySeconds': stationarySeconds,
      'nextActivity': nextActivity.name,
    });

    // Persist the return activity into the native state before publishing it
    // through Flutter. The native WorkManager retry will therefore converge to
    // the same value instead of restoring an older pre-trip status.
    await AutomaticStatusService.instance.forceNativeDrivingInactive(
      returnActivity: nextActivity,
    );

    _driving = false;
    _fastSamples = 0;
    _slowSamples = 0;
    _resetNativeStationaryTracking();
    _lastNonDriving = nextActivity;

    await UserRepository.instance.updateStatus(
      uid: uid,
      activity: nextActivity,
    );
  }

  Future<ActivityStatus?> _activityForLocation(
    String uid,
    Position position,
  ) async {
    final zones = await UserRepository.instance.getZones(uid);
    final home = _readZone(zones['home']);
    final work = _readZone(zones['work']);
    final hobby = _readZone(zones['hobby']);
    final dogWalk = _readZone(zones['dogWalk']);

    final isHome = home != null && _inside(position, home);
    ActivityStatus? decision;

    if (_zonesEnabled) {
      if (isHome) {
        decision = ActivityStatus.home;
      } else if (work != null && _inside(position, work)) {
        decision = ActivityStatus.work;
      } else if (hobby != null && _inside(position, hobby)) {
        decision = ActivityStatus.hobby;
      } else if (dogWalk != null && _inside(position, dogWalk)) {
        decision = ActivityStatus.dogWalk;
      }
    } else if (_awayEnabled && isHome) {
      decision = ActivityStatus.home;
    }

    if (decision == null && _awayEnabled && home != null && !isHome) {
      decision = ActivityStatus.away;
    }

    final decisionKey = decision?.name ?? 'none';
    if (_lastDebugZoneDecision != decisionKey) {
      _lastDebugZoneDecision = decisionKey;
      _debug('zone_decision', {
        'decision': decisionKey,
        'lat': position.latitude,
        'lng': position.longitude,
        'accuracyM': position.accuracy,
        'homeDistanceM': _distance(position, home),
        'homeRadiusM': home?.radius,
        'workDistanceM': _distance(position, work),
        'hobbyDistanceM': _distance(position, hobby),
        'dogWalkDistanceM': _distance(position, dogWalk),
        'zonesEnabled': _zonesEnabled,
        'awayEnabled': _awayEnabled,
      });
    }

    return decision;
  }

  Map<String, Object?> _positionData(Position position) {
    return {
      'lat': double.parse(position.latitude.toStringAsFixed(6)),
      'lng': double.parse(position.longitude.toStringAsFixed(6)),
      'accuracyM': double.parse(position.accuracy.toStringAsFixed(1)),
      'speedKmh': double.parse((position.speed * 3.6).toStringAsFixed(1)),
      'positionTime': position.timestamp.toIso8601String(),
    };
  }

  double? _distance(Position position, _SavedZone? zone) {
    if (zone == null) return null;
    return double.parse(
      Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        zone.lat,
        zone.lng,
      ).toStringAsFixed(1),
    );
  }

  void _debug(String event, [Map<String, Object?> data = const {}]) {
    unawaited(
      DebugLogService.instance.log(
        'location',
        event,
        data: data,
      ),
    );
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
