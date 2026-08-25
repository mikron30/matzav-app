import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/ads_service.dart';
import '../services/premium_service.dart';
import '../services/user_repository.dart';
import 'premium_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  bool _loadingZones = true;
  Map<String, dynamic> _zones = const {};

  String get uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _loadSettingsState();
  }

  Future<void> _loadSettingsState() async {
    final zones = await UserRepository.instance.getZones(uid);
    if (!mounted) return;
    setState(() {
      _zones = zones;
      _loadingZones = false;
    });
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
    return Scaffold(
      appBar: AppBar(title: const Text('הגדרות')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          const Card(
            child: ListTile(
              leading: Icon(Icons.phone_in_talk_outlined),
              title: Text('זיהוי שיחה'),
              subtitle: Text(
                'פעיל יחד עם "זיהוי אוטומטי". מזהה מצב שמע של שיחת '
                'טלפון או שיחת VoIP ומציג "בשיחה", בלי לקרוא מספר, '
                'יומן שיחות או תוכן שיחה.',
              ),
              trailing: Icon(Icons.check_circle_outline),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.bedtime_outlined),
              title: Text('מצב שינה'),
              subtitle: Text(
                'מהשעה 22:00: אם הטלפון נשאר נעול/כבוי יותר מ־10 דקות, '
                'המצב משתנה ל־"ישן". הוא חוזר למצב הקודם בפתיחה הראשונה '
                'של הטלפון.',
              ),
            ),
          ),
          const Card(
            child: ListTile(
              leading: Icon(Icons.directions_walk_outlined),
              title: Text('לא בבית'),
              subtitle: Text(
                'נוסף כמצב ידני, ובזיהוי אוטומטי הוא משמש כאשר אינך '
                'באף אחד מהאזורים שהוגדרו.',
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
                'כאשר "זיהוי אוטומטי" מופעל במסך הראשי, Matzav מפעילה '
                'זיהוי נסיעה ברקע וגם את זיהוי השינה. זיהוי שיחה פועל ללא '
                'הרשאת טלפון נוספת.',
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