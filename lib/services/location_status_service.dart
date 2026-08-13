import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:geolocator_apple/geolocator_apple.dart';

import '../models/status_models.dart';
import 'user_repository.dart';

class LocationStatusService {
  LocationStatusService._();
  static final instance = LocationStatusService._();

  StreamSubscription<Position>? _subscription;
  String? _uid;
  int _fastSamples = 0;
  int _slowSamples = 0;
  bool _driving = false;
  ActivityStatus _lastNonDriving = ActivityStatus.home;

  bool get running => _subscription != null;

  Future<void> start({
    required String uid,
    required ActivityStatus currentActivity,
  }) async {
    if (_subscription != null) return;
    _uid = uid;
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

    LocationSettings settings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20,
        intervalDuration: const Duration(seconds: 8),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'מצב אוטומטי פעיל',
          notificationText: 'מזהה נסיעה ואזורים שהגדרת',
          enableWakeLock: true,
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.high,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 20,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: true,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 20,
      );
    }

    _subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_handlePosition);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _uid = null;
    _fastSamples = 0;
    _slowSamples = 0;
    _driving = false;
  }

  Future<void> _handlePosition(Position position) async {
    final uid = _uid;
    if (uid == null) return;

    // Position.speed is meters/second. 5.5 m/s is about 20 km/h.
    if (position.speed >= 5.5) {
      _fastSamples++;
      _slowSamples = 0;
    } else if (position.speed >= 0 && position.speed <= 2.0) {
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

    if (_driving && _slowSamples >= 3) {
      _driving = false;
      final zoneActivity = await _activityForZone(uid, position);
      await UserRepository.instance.updateStatus(
        uid: uid,
        activity: zoneActivity ?? _lastNonDriving,
      );
      return;
    }

    if (!_driving && position.speed >= 0 && position.speed <= 2.0) {
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
            return ActivityStatus.home;
          case 'work':
            return ActivityStatus.work;
          case 'dogWalk':
            return ActivityStatus.dogWalk;
        }
      }
    }
    return null;
  }
}
