import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/status_models.dart';
import 'status_timer_service.dart';

/// Keeps availability on "do not disturb" while the user's activity is one of
/// the temporary busy states: meeting, phone call, or sleeping.
///
/// The availability that existed before the first busy state is stored in the
/// profile and restored only after the user leaves all busy states. This makes
/// transitions such as meeting -> call -> meeting safe without losing the
/// original availability.
class BusyAvailabilityService {
  BusyAvailabilityService._();
  static final instance = BusyAvailabilityService._();

  static const _previousField = 'busyAvailabilityPrevious';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static bool isBusyActivity(ActivityStatus activity) {
    return activity == ActivityStatus.meeting ||
        activity == ActivityStatus.onCall ||
        activity == ActivityStatus.sleeping;
  }

  Future<void> syncForActivity(String uid, ActivityStatus activity) async {
    final ref = _db.collection('profiles').doc(uid);

    await _db.runTransaction((transaction) async {
      final snapshot = await transaction.get(ref);
      final data = snapshot.data() ?? const <String, dynamic>{};
      final previousName = data[_previousField] as String?;
      final currentAvailability = availabilityFromString(
        data['availability'] as String?,
      );
      final updates = <String, dynamic>{};

      if (isBusyActivity(activity)) {
        if (previousName == null || previousName.isEmpty) {
          // Migration safety: old versions could already have forced DND but
          // did not save the previous availability. A DND timer, however, is
          // intentional and should be restored as DND until that timer ends.
          final hasAvailabilityTimer = data['availabilityTimerEndsAt'] != null;
          final previous =
              currentAvailability == AvailabilityStatus.doNotDisturb &&
                  !hasAvailabilityTimer
              ? AvailabilityStatus.canTalk
              : currentAvailability;
          updates[_previousField] = previous.name;
        }
        if (currentAvailability != AvailabilityStatus.doNotDisturb) {
          updates['availability'] = AvailabilityStatus.doNotDisturb.name;
        }
      } else if (previousName != null && previousName.isNotEmpty) {
        var restore = availabilityFromString(previousName);

        // If DND was active because of a timer and that timer expired while the
        // user was sleeping/in a meeting/on a call, restore the status that was
        // active before the timer instead of restoring stale DND.
        if (restore == AvailabilityStatus.doNotDisturb) {
          final end = StatusTimerService.dateFrom(data['availabilityTimerEndsAt']);
          if (end != null && !DateTime.now().isBefore(end)) {
            restore = availabilityFromString(
              data['availabilityTimerPrevious'] as String?,
            );
            updates['availabilityTimerEndsAt'] = FieldValue.delete();
            updates['availabilityTimerPrevious'] = FieldValue.delete();
          }
        }

        updates['availability'] = restore.name;
        updates[_previousField] = FieldValue.delete();
      }

      if (updates.isEmpty) return;
      updates['updatedAt'] = FieldValue.serverTimestamp();
      transaction.set(ref, updates, SetOptions(merge: true));
    });
  }
}
