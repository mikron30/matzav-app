import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/user_repository.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

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
        uid: FirebaseAuth.instance.currentUser!.uid,
        name: zone,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$label נשמר ברדיוס 150 מטר')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן לשמור: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('הגדרות אוטומציה')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'עמוד על המקום הרצוי ולחץ שמירה. האפליקציה תזהה כניסה לאזור ותעדכן מצב.',
          ),
          const SizedBox(height: 16),
          _ZoneTile(
            icon: Icons.home_outlined,
            title: 'הבית שלי',
            onTap: _busy ? null : () => _saveCurrentLocation('home', 'הבית'),
          ),
          _ZoneTile(
            icon: Icons.work_outline,
            title: 'העבודה שלי',
            onTap: _busy ? null : () => _saveCurrentLocation('work', 'העבודה'),
          ),
          _ZoneTile(
            icon: Icons.pets_outlined,
            title: 'אזור טיול עם הכלב',
            onTap: _busy
                ? null
                : () => _saveCurrentLocation('dogWalk', 'אזור הטיול עם הכלב'),
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
          const SizedBox(height: 24),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'זיהוי נסיעה בגרסה הזו משתמש במהירות GPS. חיבור Bluetooth לרכב הוא השדרוג הבא, כדי להפחית שימוש ב-GPS ולזהות נסיעה מהר יותר.',
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
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: FilledButton.tonal(
          onPressed: onTap,
          child: const Text('שמור מיקום נוכחי'),
        ),
      ),
    );
  }
}
