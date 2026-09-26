import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/status_models.dart';
import '../services/account_deletion_service.dart';
import '../services/ads_service.dart';
import '../services/automation_preferences.dart';
import '../services/automatic_status_service.dart';
import '../services/diagnostic_export_service.dart';
import '../services/location_status_service.dart';
import '../services/premium_service.dart';
import '../services/user_repository.dart';
import 'community_safety_screen.dart';
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
  bool _diagnosticBusy = false;
  bool _deletingAccount = false;
  AutomationFeatureSettings _automation = const AutomationFeatureSettings(
    driving: true,
    zones: true,
    away: true,
    calls: true,
    sleep: true,
  );
  Map<String, dynamic> _zones = const {};

  String get uid => FirebaseAuth.instance.currentUser!.uid;
  bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _loadSettingsState();
  }

  Future<void> _loadSettingsState() async {
    var automation = await AutomationPreferences.instance.load();
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
      // Android supports native call/sleep monitoring. iOS uses CallKit for
      // calls and the background-location service for conservative sleep inference.
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
        away: value,
        calls: value,
        sleep: value,
      ),
      message: value
          ? 'כל אפשרויות הזיהוי האוטומטי הנתמכות הופעלו.'
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

  Future<void> _shareDiagnostics() async {
    if (_diagnosticBusy) return;
    setState(() => _diagnosticBusy = true);
    try {
      await DiagnosticExportService.instance.shareReport(uid);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן לייצא את דוח הדיבוג: $e')),
      );
    } finally {
      if (mounted) setState(() => _diagnosticBusy = false);
    }
  }

  Future<void> _copyDiagnostics() async {
    if (_diagnosticBusy) return;
    setState(() => _diagnosticBusy = true);
    try {
      await DiagnosticExportService.instance.copyReport(uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('דוח הדיבוג הועתק ללוח.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן להעתיק את דוח הדיבוג: $e')),
      );
    } finally {
      if (mounted) setState(() => _diagnosticBusy = false);
    }
  }

  Future<void> _clearDiagnostics() async {
    await DiagnosticExportService.instance.clearLogs();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('היסטוריית הדיבוג נוקתה.')),
    );
  }

  Future<void> _confirmDeleteAccount() async {
    if (_deletingAccount) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('מחיקת החשבון'),
          content: const Text(
            'הפעולה תמחק לצמיתות את חשבון Matzav, הפרופיל, הסטטוס, '
            'המיקומים השמורים, רשימת החברים ובקשות ההתראה הקשורות לחשבון.\n\n'
            'לא ניתן לבטל את הפעולה לאחר השלמתה. רכישות שבוצעו דרך App Store '
            'או Google Play נשארות ברישומי החנות בהתאם למדיניות החנות.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ביטול'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('מחק לצמיתות'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;
    setState(() => _deletingAccount = true);

    try {
      // Stop automatic publishers first so they cannot recreate a profile
      // during the short interval in which the server removes the account.
      try {
        await LocationStatusService.instance.stop();
      } catch (_) {}
      try {
        await AutomaticStatusService.instance.stop();
      } catch (_) {}
      await AccountDeletionService.instance.deleteCurrentAccount();
    } catch (error) {
      if (!mounted) return;
      final text = error.toString().replaceFirst('HttpException: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text)),
      );
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final supportedAutomationEnabled = _automation.anyEnabled;
    final supportedAutomationAllEnabled = _automation.allEnabled;
    final masterSubtitle = supportedAutomationAllEnabled
        ? 'כל חמשת הזיהויים פעילים'
        : supportedAutomationEnabled
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
                  value: supportedAutomationEnabled,
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
                  subtitle: Text(
                    _isIos
                        ? 'מזהה נסיעה אוטומטית לפי מהירות ושירותי המיקום. '
                          'לאוטומציה ברקע יש לאשר גישה למיקום גם כשהאפליקציה אינה בשימוש.'
                        : 'מזהה נסיעה גם כשהאפליקציה סגורה. יש לאשר הרשאת '
                          '"פעילות גופנית". GPS משמש גם לזיהוי לפי מהירות.',
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
                  secondary: const Icon(Icons.place_outlined),
                  title: const Text('זיהוי בית ואזורים'),
                  subtitle: const Text(
                    'מזהה את אזורי הבית, העבודה, התחביב וטיול הכלב שהוגדרו למטה.',
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  value: _automation.away,
                  onChanged: _automationBusy
                      ? null
                      : (value) => _applyAutomationSettings(
                            _automation.copyWith(away: value),
                          ),
                  secondary: const Icon(Icons.directions_walk_outlined),
                  title: const Text('זיהוי לא בבית'),
                  subtitle: const Text(
                    'כאשר מיקום הבית מוגדר, GPS מעביר אוטומטית ל־"לא בבית" '
                    'כשנמצאים מחוץ לבית. אזור עבודה/תחביב/כלב מקבל עדיפות '
                    'אם זיהוי האזורים פעיל.',
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
                  subtitle: Text(
                    _isIos
                        ? 'מזהה שיחה פעילה דרך CallKit ומציג "בשיחה", בלי '
                          'לקרוא מספר טלפון, זהות מתקשר, יומן שיחות או תוכן.'
                        : 'מזהה שיחת טלפון או VoIP ומציג "בשיחה", בלי לקרוא '
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
                  subtitle: Text(
                    _isIos
                        ? 'מזהה שינה באופן משוער כאשר המכשיר נשאר בבית ללא '
                          'תנועה ממושכת בשעות הלילה. לא נקרא מידע רפואי או '
                          'נתוני HealthKit.'
                        : 'משתמש בזיהוי השינה ובחיישני המכשיר; אם המידע '
                          'לא זמין, מופעל fallback שמרני של חוסר שימוש.',
                  ),
                ),
              ],
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.do_not_disturb_on_outlined),
              title: const Text('נא לא להפריע בזמן עסוק'),
              subtitle: Text(
                'בשינה, בפגישה או בשיחה הזמינות עוברת אוטומטית ל־'
                '"נא לא להפריע" וחוזרת לערך שהיה לפני כן בסיום.',
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
            'עמוד על המקום הרצוי ולחץ שמירה. "תחביב" יכול להיות מגרש '
            'טניס, מגרש כדורגל, חדר כושר, חוג או כל מקום קבוע אחר.',
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
              icon: Icons.favorite_outline,
              title: 'מיקום התחביב שלי',
              subtitle: _zoneSubtitle('hobby'),
              configured: _zoneConfigured('hobby'),
              onTap: _busy
                  ? null
                  : () => _saveCurrentLocation('hobby', 'מיקום התחביב'),
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
          Text(
            'אבחון תקלות',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('ייצוא דוח דיבוג'),
                  subtitle: const Text(
                    'אם המצב שגוי או תקוע, לחץ מיד ושלח את הדוח. הוא כולל '
                    'מצב נוכחי, הרשאות, GPS/מהירות, מרחק מהאזורים והיסטוריית '
                    'אירועי זיהוי אחרונים. שום דבר לא נשלח אוטומטית.',
                  ),
                  trailing: _diagnosticBusy
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.share_outlined),
                  onTap: _diagnosticBusy ? null : _shareDiagnostics,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: const Text('העתק דוח ללוח'),
                  subtitle: const Text('שימושי אם רוצים להדביק את הדוח ישירות בצ׳אט.'),
                  onTap: _diagnosticBusy ? null : _copyDiagnostics,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('נקה היסטוריית דיבוג'),
                  onTap: _diagnosticBusy ? null : _clearDiagnostics,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'קהילה ובטיחות',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.policy_outlined),
                  title: const Text('כללי קהילה ותנאי שימוש'),
                  subtitle: const Text(
                    'אפס סובלנות לתוכן פוגעני, הטרדה ושימוש לרעה.',
                  ),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CommunityTermsScreen(
                        uid: uid,
                        readOnly: true,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('צור קשר עם התמיכה'),
                  subtitle: const Text(
                    'תמיכה, פרטיות, בטיחות או דיווח כללי.',
                  ),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SupportContactScreen(uid: uid),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'חשבון',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: _deletingAccount
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.delete_forever_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
              title: Text(
                _deletingAccount ? 'מוחק את החשבון...' : 'מחק חשבון',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: const Text(
                'מחיקה לצמיתות של החשבון והנתונים הקשורים אליו.',
              ),
              onTap: _deletingAccount ? null : _confirmDeleteAccount,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'אפשר להפעיל כל מנגנון זיהוי בנפרד. המתג העליון מפעיל '
                'או מכבה את חמשתם יחד. זיהוי "לא בבית" וזיהוי השינה ב־iOS '
                'דורשים שמיקום הבית יהיה שמור.',
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
