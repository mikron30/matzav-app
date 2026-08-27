import 'package:shared_preferences/shared_preferences.dart';

class AutomationFeatureSettings {
  const AutomationFeatureSettings({
    required this.driving,
    required this.zones,
    required this.away,
    required this.calls,
    required this.sleep,
  });

  final bool driving;
  final bool zones;
  final bool away;
  final bool calls;
  final bool sleep;

  bool get allEnabled => driving && zones && away && calls && sleep;
  bool get anyEnabled => driving || zones || away || calls || sleep;
  bool get locationEnabled => driving || zones || away;
  bool get nativeEnabled => calls || sleep;

  AutomationFeatureSettings copyWith({
    bool? driving,
    bool? zones,
    bool? away,
    bool? calls,
    bool? sleep,
  }) {
    return AutomationFeatureSettings(
      driving: driving ?? this.driving,
      zones: zones ?? this.zones,
      away: away ?? this.away,
      calls: calls ?? this.calls,
      sleep: sleep ?? this.sleep,
    );
  }
}

class AutomationPreferences {
  AutomationPreferences._();
  static final instance = AutomationPreferences._();

  // Kept for compatibility with HomeScreen and older installed versions.
  static const legacyMasterKey = 'matzav_automation_enabled_v25';
  static const drivingKey = 'matzav_auto_driving_v31';
  static const zonesKey = 'matzav_auto_zones_v31';
  static const callsKey = 'matzav_auto_calls_v31';
  static const sleepKey = 'matzav_auto_sleep_v31';
  static const awayKey = 'matzav_auto_away_v34';

  Future<AutomationFeatureSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final legacyDefault = prefs.getBool(legacyMasterKey) ?? true;
    final zonesDefault = prefs.getBool(zonesKey) ?? legacyDefault;

    return AutomationFeatureSettings(
      driving: prefs.getBool(drivingKey) ?? legacyDefault,
      zones: zonesDefault,
      // Migration: users who had location-zone detection enabled get the
      // restored "not home" detector enabled as well. If they had zones off,
      // away detection stays off until they explicitly enable it.
      away: prefs.getBool(awayKey) ?? zonesDefault,
      calls: prefs.getBool(callsKey) ?? legacyDefault,
      sleep: prefs.getBool(sleepKey) ?? legacyDefault,
    );
  }

  Future<void> save(AutomationFeatureSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool(drivingKey, settings.driving),
      prefs.setBool(zonesKey, settings.zones),
      prefs.setBool(awayKey, settings.away),
      prefs.setBool(callsKey, settings.calls),
      prefs.setBool(sleepKey, settings.sleep),
      // The old master flag now means "at least one automatic feature is on".
      // This lets older startup code keep restoring automation correctly.
      prefs.setBool(legacyMasterKey, settings.anyEnabled),
    ]);
  }

  Future<AutomationFeatureSettings> setAll(bool enabled) async {
    final settings = AutomationFeatureSettings(
      driving: enabled,
      zones: enabled,
      away: enabled,
      calls: enabled,
      sleep: enabled,
    );
    await save(settings);
    return settings;
  }
}
