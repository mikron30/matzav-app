enum ActivityStatus {
  home,
  away,
  work,
  hobby,
  meeting,
  driving,
  onCall,
  sleeping,
  dogWalk,
}

enum AvailabilityStatus { freeToTalk, canTalk, doNotDisturb }

extension ActivityStatusUi on ActivityStatus {
  String get label => switch (this) {
        ActivityStatus.home => 'בבית',
        ActivityStatus.away => 'לא בבית',
        ActivityStatus.work => 'בעבודה',
        ActivityStatus.hobby => 'בתחביב',
        ActivityStatus.meeting => 'בפגישה',
        ActivityStatus.driving => 'בנסיעה',
        ActivityStatus.onCall => 'בשיחה',
        ActivityStatus.sleeping => 'ישן',
        ActivityStatus.dogWalk => 'טיול עם הכלב',
      };

  String get emoji => switch (this) {
        ActivityStatus.home => '🏠',
        ActivityStatus.away => '🚶',
        ActivityStatus.work => '💼',
        ActivityStatus.hobby => '🎯',
        ActivityStatus.meeting => '📅',
        ActivityStatus.driving => '🚗',
        ActivityStatus.onCall => '📞',
        ActivityStatus.sleeping => '😴',
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
