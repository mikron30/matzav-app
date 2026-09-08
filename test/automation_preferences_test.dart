import 'package:flutter_test/flutter_test.dart';
import 'package:matzav_app/services/automation_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('driving without calls or sleep still starts native monitoring', () {
    const settings = AutomationFeatureSettings(
      driving: true, zones: false, away: false, calls: false, sleep: false,
    );
    expect(settings.nativeEnabled, isTrue);
  });

  test('location zones alone do not request native activity monitoring', () {
    const settings = AutomationFeatureSettings(
      driving: false, zones: true, away: true, calls: false, sleep: false,
    );
    expect(settings.nativeEnabled, isFalse);
    expect(settings.locationEnabled, isTrue);
  });

  test('driving-only settings survive saving and reloading', () async {
    SharedPreferences.setMockInitialValues({});
    const settings = AutomationFeatureSettings(
      driving: true, zones: false, away: false, calls: false, sleep: false,
    );
    await AutomationPreferences.instance.save(settings);
    final restored = await AutomationPreferences.instance.load();
    expect(restored.driving, isTrue);
    expect(restored.calls, isFalse);
    expect(restored.sleep, isFalse);
    expect(restored.nativeEnabled, isTrue);
  });
}
