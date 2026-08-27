import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_models.dart';
import '../services/ads_service.dart';
import '../services/automation_preferences.dart';
import '../services/automatic_status_service.dart';
import '../services/location_status_service.dart';
import '../services/premium_service.dart';
import '../services/user_repository.dart';
import 'premium_screen.dart';

class ThemeService extends ChangeNotifier {
  ThemeService._();
  static final instance = ThemeService._();

  static const _darkModeKey = 'matzav_dark_mode';

  bool _isDarkMode = false;
  bool _initialized = false;

  bool get isDarkMode => _isDarkMode;
  ThemeMode get themeMode => _isDarkMode ? ThemeMode.dark : ThemeMode.light;

  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _isDarkMode = prefs.getBool(_darkModeKey) ?? false;
    _initialized = true;
  }

  Future<void> setDarkMode(bool value) async {
    if (_isDarkMode == value && _initialized) return;
    _isDarkMode = value;
    _initialized = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkModeKey, value);
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  bool _loadingZones = true;
  bool _automationBusy = false;
  AutomationFeatureSettings _automation = const AutomationFeatureSettings(
    driving: true,
    zones: true,
    calls: true,
    sleep: true,
  );
  Map<String, dynamic> _zones = const {};

  String get uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _loadSettingsState();
  }

  Future<void> _loadSettingsState() async {
    final automation = await AutomationPreferences.instance.load();
    final zones = await UserRepository.instance.getZones(uid);
    if (!mounted) return;
    setState(() {
      _automation = automation;
      _zones = zones;
      _loadingZones = false;
    });
  }

  Future<void> _applyAutomationSettings(
    AutomationFeatureSettings settings, {
    String? message,
  }) async {
    if (_automationBusy) return;
    setState(() => _automationBusy = true);

    await AutomationPreferences.instance.save(settings);
    if (mounted) setState(() => _automation = settings);

    try {
      // Native call/sleep overrides are refreshed first. If one of them was
      // just disabled while active, this restores the real activity before
      // the location service snapshots its return state.
      await AutomaticStatusService.instance.refresh(uid: uid);

      final snapshot = await UserRepository.instance.profileStream(uid).first;
      final currentActivity = activityFromString(
        snapshot.data()?['activity'] as String?,
      );
      await LocationStatusService.instance.refresh(
        uid: uid,
        currentActivity: currentActivity,
      );

      if (!mounted || message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'ההגדרה נשמרה, אבל לא ניתן להפעיל כרגע את הזיהוי: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _automationBusy = false);
    }
  }

  Future<void> _setAllAutomation(bool value) async {
    await _applyAutomationSettings(
      AutomationFeatureSettings(
        driving: value,
        zones: value,
        calls: value,
        sleep: value,
      ),
      message: value
          ? 'כל אפשרויות הזיהוי האוטומטי הופעלו.'
          : 'כל אפשרויות הזיהוי האוטומטי כובו.',
    );
  }

  Future<void> _saveCurrentLocation(String zone, String label) async {
    setState(() => _busy = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('אין הרשאת מיקום');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await UserRepository.instance.saveZone(
        uid: uid,
        name: zone,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      final zones = await UserRepository.instance.getZones(uid);
      if (!mounted) return;
      setState(() => _zones = zones);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label נשמר ברדיוס 150 מטר')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('לא ניתן לשמור: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _zoneSubtitle(String zone) {
    final raw = _zones[zone];
    if (raw is! Map) return 'לא הוגדר';
    final map = Map<String, dynamic>.from(raw);
    final lat = (map['lat'] as num?)?.toDouble();
    final lng = (map['lng'] as num?)?.toDouble();
    final radius = (map['radius'] as num?)?.toDouble() ?? 150;
    if (lat == null || lng == null) return 'לא הוגדר';
    return 'הוגדר • ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)} • '
        'רדיוס ${radius.round()} מ׳';
  }

  bool _zoneConfigured(String zone) {
    final raw = _zones[zone];
    if (raw is! Map) return false;
    final map = Map<String, dynamic>.from(raw);
    return map['lat'] is num && map['lng'] is num;
  }

  Future<void> _showPrivacyOptions() async {
    final error = await AdsService.instance.showPrivacyOptionsForm();
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('לא ניתן לפתוח את הגדרות הפרטיות: ${error.message}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final masterSubtitle = _automation.allEnabled
        ? 'כל ארבעת הזיהויים פעילים'
        : _automation.anyEnabled
        ? 'חלק מהזיהויים פעילים — אפשר לשלוט בכל אחד בנפרד'
        : 'כל הזיהויים כבויים';

    return Scaffold(
      appBar: AppBar(title: const Text('הגדרות')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'מראה',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: ThemeService.instance,
            builder: (context, _) {
              final isDark = ThemeService.instance.isDarkMode;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          isDark
                              ? Icons.dark_mode_outlined
                              : Icons.light_mode_outlined,
                        ),
                        title: const Text('ערכת נושא'),
                        subtitle: Text(
                          isDark
                              ? 'מצב כהה — רקע כהה וטקסט בהיר'
                              : 'מצב בהיר — רקע בהיר וטקסט כהה',
                        ),
                      ),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment<bool>(
                            value: false,
                            icon: Icon(Icons.light_mode_outlined),
                            label: Text('בהיר'),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            icon: Icon(Icons.dark_mode_outlined),
                            label: Text('כהה'),
                          ),
                        ],
                        selected: {isDark},
                        onSelectionChanged: (selection) {
                          ThemeService.instance.setDarkMode(selection.first);
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: PremiumService.instance,
            builder: (context, _) => Card(
              child: ListTile(
                leading: Icon(
                  PremiumService.instance.isPremium
                      ? Icons.verified
                      : Icons.workspace_premium_outlined,
                ),
                title: Text(
                  PremiumService.instance.isPremium
                      ? 'Matzav Premium פעיל'
                      : 'שדרוג ל־Matzav Premium',
                ),
                subtitle: Text(
                  PremiumService.instance.isPremium
                      ? 'חברים ללא הגבלה וללא פרסומות.'
                      : 'יותר מ־7 חברים והסרת פרסומות.',
                ),
                trailing: const Icon(Icons.chevron_left),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PremiumScreen(uid: uid),
                  ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: AdsService.instance,
            builder: (context, _) => AdsService.instance.privacyOptionsRequired
                ? Card(
                    child: ListTile(
                      leading: const Icon(Icons.privacy_tip_outlined),
                      title: const Text('אפשרויות פרטיות של פרסומות'),
                      subtitle: const Text(
                        'שינוי הבחירות לגבי שימוש בנתונים לפרסומות.',
                      ),
                      onTap: _showPrivacyOptions,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 16),
          Text(
            'זיהוי אוטומטי',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  value: _automation.anyEnabled,
                  onChanged: _automationBusy ? null : _setAllAutomation,
                  secondary: const Icon(Icons.auto_awesome_motion_outlined),
                  title: const Text('הפעל / כבה את הכל'),
                  subtitle: Text(masterSubtitle),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: _automation.driving,
                  onChanged: _automationBusy
                      ? null
                      : (value) => _applyAutomationSettings(
                            _automation.copyWith(driving: value),
                          ),
                  secondary: const Icon(Icons.directions_car_outlined),
                  title: const Text('זיהוי נהיגה'),
                  subtitle: const Text(
                    'משתמש ב־GPS ובמהירות כדי לעבור אוטומטית למצב "בנסיעה".',
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: _automation.zones,
                  onChanged: _automationBusy
                      ? null
                      : (value) => _applyAutomationSettings(
                            _automation.copyWith(zones: value),
                          ),
                  secondary: const Icon(Icons.home_outlined),
                  title: const Text('זיהוי בית ואזורים'),
                  subtitle: const Text(
                    'מזהה את אזורי הבית, העבודה וטיול הכלב שהוגדרו למטה.',
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: _automation.calls,
                  onChanged: _automationBusy
                      ? null
                      : (value) => _applyAutomationSettings(
                            _automation.copyWith(calls: value),
                          ),
                  secondary: const Icon(Icons.phone_in_talk_outlined),
                  title: const Text('זיהוי שיחה'),
                  subtitle: const Text(
                    'מזהה שיחת טלפון או VoIP ומציג "בשיחה", בלי לקרוא '
                    'מספר, יומן שיחות או תוכן שיחה.',
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: _automation.sleep,
                  onChanged: _automationBusy
                      ? null
                      : (value) => _applyAutomationSettings(
                            _automation.copyWith(sleep: value),
                          ),
                  secondary: const Icon(Icons.bedtime_outlined),
                  title: const Text('זיהוי שינה'),
                  subtitle: const Text(
                    'משתמש ב־Google Sleep API ובחיישני המכשיר; אם המידע '
                    'לא זמין, מופעל fallback שמרני של חוסר שימוש.',
                  ),
                ),
              ],
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.do_not_disturb_on_outlined),
              title: Text('נא לא להפריע בזמן עסוק'),
              subtitle: Text(
                'בשינה, בפגישה או בשיחה הזמינות עוברת אוטומטית ל־"נא לא '
                'להפריע" וחוזרת לערך שהיה לפני כן בסיום.',
              ),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.directions_walk_outlined),
              title: Text('לא בבית'),
              subtitle: Text(
                'מצב "לא בבית" נשאר מצב ידני. זיהוי האזורים משנה למצב '
                'המתאים רק כאשר נכנסים לאזור שהוגדר.',
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'אוטומציה לפי מיקום',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'עמוד על המקום הרצוי ולחץ שמירה. כאן ניתן גם לראות אם כבר '
            'הוגדר מיקום ואת הקואורדינטות שנשמרו.',
          ),
          const SizedBox(height: 16),
          if (_loadingZones)
            const Center(child: CircularProgressIndicator())
          else ...[
            _ZoneTile(
              icon: Icons.home_outlined,
              title: 'הבית שלי',
              subtitle: _zoneSubtitle('home'),
              configured: _zoneConfigured('home'),
              onTap: _busy
                  ? null
                  : () => _saveCurrentLocation('home', 'הבית'),
            ),
            _ZoneTile(
              icon: Icons.work_outline,
              title: 'העבודה שלי',
              subtitle: _zoneSubtitle('work'),
              configured: _zoneConfigured('work'),
              onTap: _busy
                  ? null
                  : () => _saveCurrentLocation('work', 'העבודה'),
            ),
            _ZoneTile(
              icon: Icons.pets_outlined,
              title: 'אזור טיול עם הכלב',
              subtitle: _zoneSubtitle('dogWalk'),
              configured: _zoneConfigured('dogWalk'),
              onTap: _busy
                  ? null
                  : () => _saveCurrentLocation(
                        'dogWalk',
                        'אזור הטיול עם הכלב',
                      ),
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
          const SizedBox(height: 24),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'אפשר להפעיל כל מנגנון זיהוי בנפרד. המתג העליון מפעיל או '
                'מכבה את ארבעתם יחד. הרשאות Android נדרשות רק לפיצ׳רים '
                'שהפעלת.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoneTile extends StatelessWidget {
  const _ZoneTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.configured,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool configured;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          icon,
          color: configured ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: FilledButton.tonal(
          onPressed: onTap,
          child: Text(configured ? 'עדכן' : 'שמור מיקום'),
        ),
      ),
    );
  }
}
