enum ActivityStatus { home, work, meeting, driving, dogWalk }

enum AvailabilityStatus { freeToTalk, canTalk, doNotDisturb }

extension ActivityStatusUi on ActivityStatus {
  String get label => switch (this) {
        ActivityStatus.home => 'בבית',
        ActivityStatus.work => 'בעבודה',
        ActivityStatus.meeting => 'בפגישה',
        ActivityStatus.driving => 'בנסיעה',
        ActivityStatus.dogWalk => 'טיול עם הכלב',
      };

  String get emoji => switch (this) {
        ActivityStatus.home => '🏠',
        ActivityStatus.work => '💼',
        ActivityStatus.meeting => '📅',
        ActivityStatus.driving => '🚗',
        ActivityStatus.dogWalk => '🐕',
      };
}

extension AvailabilityStatusUi on AvailabilityStatus {
  String get label => switch (this) {
        AvailabilityStatus.freeToTalk => 'פנוי לשיחה',
        AvailabilityStatus.canTalk => 'יכול לדבר',
        AvailabilityStatus.doNotDisturb => 'נא לא להפריע',
      };

  String get emoji => switch (this) {
        AvailabilityStatus.freeToTalk => '🟢',
        AvailabilityStatus.canTalk => '🟡',
        AvailabilityStatus.doNotDisturb => '🔴',
      };
}

ActivityStatus activityFromString(String? value) {
  return ActivityStatus.values.firstWhere(
    (e) => e.name == value,
    orElse: () => ActivityStatus.home,
  );
}

AvailabilityStatus availabilityFromString(String? value) {
  return AvailabilityStatus.values.firstWhere(
    (e) => e.name == value,
    orElse: () => AvailabilityStatus.canTalk,
  );
}
