import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_models.dart';
import 'busy_availability_service.dart';

class StatusTimerService {
  StatusTimerService._();
  static final instance = StatusTimerService._();

  static const _activityEndKey = 'v22_activity_timer_end_ms';
  static const _activityPreviousKey = 'v22_activity_timer_previous';
  static const _availabilityEndKey = 'v22_availability_timer_end_ms';
  static const _availabilityPreviousKey = 'v22_availability_timer_previous';

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  Timer? _activityTimer;
  Timer? _availabilityTimer;

  static DateTime? dateFrom(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  static ActivityStatus effectiveActivity(Map<String, dynamic> profile) {
    final current = activityFromString(profile['activity'] as String?);
    if (current != ActivityStatus.meeting) return current;

    final end = dateFrom(profile['activityTimerEndsAt']);
    if (end == null || DateTime.now().isBefore(end)) return current;

    return activityFromString(profile['activityTimerPrevious'] as String?);
  }

  static AvailabilityStatus effectiveAvailability(
    Map<String, dynamic> profile,
  ) {
    final current = availabilityFromString(profile['availability'] as String?);
    if (current != AvailabilityStatus.doNotDisturb) return current;

    final end = dateFrom(profile['availabilityTimerEndsAt']);
    if (end == null || DateTime.now().isBefore(end)) return current;

    return availabilityFromString(
      profile['availabilityTimerPrevious'] as String?,
    );
  }

  static DateTime? activeActivityTimerEnd(Map<String, dynamic> profile) {
    if (activityFromString(profile['activity'] as String?) !=
        ActivityStatus.meeting) {
      return null;
    }
    final end = dateFrom(profile['activityTimerEndsAt']);
    if (end == null || !DateTime.now().isBefore(end)) return null;
    return end;
  }

  static DateTime? activeAvailabilityTimerEnd(Map<String, dynamic> profile) {
    if (availabilityFromString(profile['availability'] as String?) !=
        AvailabilityStatus.doNotDisturb) {
      return null;
    }
    final end = dateFrom(profile['availabilityTimerEndsAt']);
    if (end == null || !DateTime.now().isBefore(end)) return null;
    return end;
  }

  Future<void> startActivityTimer({
    required String uid,
    required ActivityStatus previous,
    required DateTime endsAt,
  }) async {
    _validateEnd(endsAt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_activityEndKey, endsAt.millisecondsSinceEpoch);
    await prefs.setString(_activityPreviousKey, previous.name);

    await _db.collection('profiles').doc(uid).set({
      'activity': ActivityStatus.meeting.name,
      'activityTimerEndsAt': Timestamp.fromDate(endsAt),
      'activityTimerPrevious': previous.name,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await BusyAvailabilityService.instance.syncForActivity(
      uid,
      ActivityStatus.meeting,
    );

    _scheduleActivity(uid, endsAt);
  }

  Future<void> startAvailabilityTimer({
    required String uid,
    required AvailabilityStatus previous,
    required DateTime endsAt,
  }) async {
    _validateEnd(endsAt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_availabilityEndKey, endsAt.millisecondsSinceEpoch);
    await prefs.setString(_availabilityPreviousKey, previous.name);

    await _db.collection('profiles').doc(uid).set({
      'availability': AvailabilityStatus.doNotDisturb.name,
      'availabilityTimerEndsAt': Timestamp.fromDate(endsAt),
      'availabilityTimerPrevious': previous.name,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _scheduleAvailability(uid, endsAt);
  }

  Future<void> setManualActivity({
    required String uid,
    required ActivityStatus activity,
  }) async {
    _activityTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activityEndKey);
    await prefs.remove(_activityPreviousKey);
    await _db.collection('profiles').doc(uid).set({
      'activity': activity.name,
      'activityTimerEndsAt': FieldValue.delete(),
      'activityTimerPrevious': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await BusyAvailabilityService.instance.syncForActivity(uid, activity);
  }

  Future<void> setManualAvailability({
    required String uid,
    required AvailabilityStatus availability,
  }) async {
    _availabilityTimer?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_availabilityEndKey);
    await prefs.remove(_availabilityPreviousKey);
    await _db.collection('profiles').doc(uid).set({
      'availability': availability.name,
      'availabilityTimerEndsAt': FieldValue.delete(),
      'availabilityTimerPrevious': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    final profile = await _db.collection('profiles').doc(uid).get();
    final currentActivity = activityFromString(
      profile.data()?['activity'] as String?,
    );
    await BusyAvailabilityService.instance.syncForActivity(
      uid,
      currentActivity,
    );
  }

  Future<void> syncAndSchedule(
    String uid,
    Map<String, dynamic> profile,
  ) async {
    final activityEnd = dateFrom(profile['activityTimerEndsAt']);
    final activityPrevious = profile['activityTimerPrevious'] as String?;
    final availabilityEnd = dateFrom(profile['availabilityTimerEndsAt']);
    final availabilityPrevious = profile['availabilityTimerPrevious'] as String?;

    final prefs = await SharedPreferences.getInstance();
    if (activityEnd != null && activityPrevious != null) {
      await prefs.setInt(_activityEndKey, activityEnd.millisecondsSinceEpoch);
      await prefs.setString(_activityPreviousKey, activityPrevious);
    }
    if (availabilityEnd != null && availabilityPrevious != null) {
      await prefs.setInt(
        _availabilityEndKey,
        availabilityEnd.millisecondsSinceEpoch,
      );
      await prefs.setString(_availabilityPreviousKey, availabilityPrevious);
    }

    if (activityEnd != null) {
      if (DateTime.now().isBefore(activityEnd)) {
        _scheduleActivity(uid, activityEnd);
      } else {
        await _restoreActivityIfPossible(uid);
      }
    }

    if (availabilityEnd != null) {
      if (DateTime.now().isBefore(availabilityEnd)) {
        _scheduleAvailability(uid, availabilityEnd);
      } else {
        await _restoreAvailability(uid);
      }
    }

    await BusyAvailabilityService.instance.syncForActivity(
      uid,
      effectiveActivity(profile),
    );
  }

  Future<bool> isMeetingTimerActive() async {
    final prefs = await SharedPreferences.getInstance();
    final endMs = prefs.getInt(_activityEndKey);
    if (endMs == null) return false;
    return DateTime.now().millisecondsSinceEpoch < endMs;
  }

  /// If [candidate] is the timed meeting status but the timer has already
  /// expired, returns the status that existed before the meeting. This is used
  /// when a temporary automatic override (driving/call/sleep) finishes.
  Future<ActivityStatus> resolveActivityReturn(
    String uid,
    ActivityStatus candidate,
  ) async {
    if (candidate != ActivityStatus.meeting) return candidate;

    final snapshot = await _db.collection('profiles').doc(uid).get();
    final data = snapshot.data() ?? const <String, dynamic>{};
    final end = dateFrom(data['activityTimerEndsAt']);
    if (end == null || DateTime.now().isBefore(end)) return candidate;

    final previous = activityFromString(data['activityTimerPrevious'] as String?);
    await _clearActivityTimerMetadata(uid);
    return previous;
  }

  Future<void> _restoreActivityIfPossible(String uid) async {
    final ref = _db.collection('profiles').doc(uid);
    final snapshot = await ref.get();
    final data = snapshot.data() ?? const <String, dynamic>{};
    final end = dateFrom(data['activityTimerEndsAt']);
    if (end == null || DateTime.now().isBefore(end)) return;

    final current = activityFromString(data['activity'] as String?);
    if (current == ActivityStatus.meeting) {
      final previous = activityFromString(
        data['activityTimerPrevious'] as String?,
      );
      await ref.set({
        'activity': previous.name,
        'activityTimerEndsAt': FieldValue.delete(),
        'activityTimerPrevious': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await BusyAvailabilityService.instance.syncForActivity(uid, previous);
      await _clearActivityPrefs();
    }
    // If call/sleep/driving is currently overriding the meeting, keep the
    // timer metadata. The override-return path will resolve the expired timer.
  }

  Future<void> _restoreAvailability(String uid) async {
    final ref = _db.collection('profiles').doc(uid);
    final snapshot = await ref.get();
    final data = snapshot.data() ?? const <String, dynamic>{};
    final end = dateFrom(data['availabilityTimerEndsAt']);
    if (end == null || DateTime.now().isBefore(end)) return;

    final previous = availabilityFromString(
      data['availabilityTimerPrevious'] as String?,
    );
    await ref.set({
      'availability': previous.name,
      'availabilityTimerEndsAt': FieldValue.delete(),
      'availabilityTimerPrevious': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _clearAvailabilityPrefs();

    final updatedProfile = await ref.get();
    final currentActivity = activityFromString(
      updatedProfile.data()?['activity'] as String?,
    );
    await BusyAvailabilityService.instance.syncForActivity(
      uid,
      currentActivity,
    );
  }

  Future<void> _clearActivityTimerMetadata(String uid) async {
    await _db.collection('profiles').doc(uid).set({
      'activityTimerEndsAt': FieldValue.delete(),
      'activityTimerPrevious': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _clearActivityPrefs();
  }

  Future<void> _clearActivityPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activityEndKey);
    await prefs.remove(_activityPreviousKey);
  }

  Future<void> _clearAvailabilityPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_availabilityEndKey);
    await prefs.remove(_availabilityPreviousKey);
  }

  void _scheduleActivity(String uid, DateTime end) {
    _activityTimer?.cancel();
    final delay = end.difference(DateTime.now());
    if (delay <= Duration.zero) {
      unawaited(_restoreActivityIfPossible(uid));
      return;
    }
    _activityTimer = Timer(delay, () {
      unawaited(_restoreActivityIfPossible(uid));
    });
  }

  void _scheduleAvailability(String uid, DateTime end) {
    _availabilityTimer?.cancel();
    final delay = end.difference(DateTime.now());
    if (delay <= Duration.zero) {
      unawaited(_restoreAvailability(uid));
      return;
    }
    _availabilityTimer = Timer(delay, () {
      unawaited(_restoreAvailability(uid));
    });
  }

  void cancelLocalTimers() {
    _activityTimer?.cancel();
    _availabilityTimer?.cancel();
    _activityTimer = null;
    _availabilityTimer = null;
  }

  void _validateEnd(DateTime endsAt) {
    final duration = endsAt.difference(DateTime.now());
    if (duration <= Duration.zero || duration > const Duration(days: 1)) {
      throw ArgumentError('Status timer must be between 1 minute and 24 hours.');
    }
  }
}
