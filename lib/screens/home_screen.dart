import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/status_models.dart';
import '../services/auth_service.dart';
import '../services/contact_invite_service.dart';
import '../services/location_status_service.dart';
import '../services/phone_hint_service.dart';
import '../services/user_repository.dart';
import 'add_friends_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _automationOn = false;
  bool _phoneSetupChecked = false;

  String get uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    UserRepository.instance.resolvePendingFriends(uid);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePhoneIdentity();
    });
  }

  Future<void> _ensurePhoneIdentity() async {
    if (_phoneSetupChecked) return;
    _phoneSetupChecked = true;

    try {
      final existingPhone =
          await UserRepository.instance.getRegisteredPhone(uid);
      if (existingPhone != null && existingPhone.isNotEmpty) return;

      final hintedPhone =
          await PhoneHintService.instance.requestPhoneNumberHint();
      if (!mounted) return;

      final selectedPhone = await showDialog<String>(
        context: context,
        builder: (context) => _PhoneSetupDialog(
          initialPhone: hintedPhone ?? '',
        ),
      );
      if (selectedPhone == null || selectedPhone.trim().isEmpty) return;

      await UserRepository.instance.registerPhoneNumber(
        uid: uid,
        phone: selectedPhone,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('מספר הטלפון נשמר. מתבצע זיהוי מחדש של החברים.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן לשמור את מספר הטלפון: $e')),
      );
    }
  }

  @override
  void dispose() {
    LocationStatusService.instance.stop();
    super.dispose();
  }

  Future<void> _toggleAutomation(
    bool value,
    ActivityStatus currentActivity,
  ) async {
    try {
      if (value) {
        await LocationStatusService.instance.start(
          uid: uid,
          currentActivity: currentActivity,
        );
      } else {
        await LocationStatusService.instance.stop();
      }
      if (mounted) setState(() => _automationOn = value);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('האוטומציה לא הופעלה: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Matzav'),
        actions: [
          IconButton(
            tooltip: 'הגדרות מיקום',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'התנתק',
            onPressed: AuthService.instance.signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: UserRepository.instance.profileStream(uid),
        builder: (context, profileSnapshot) {
          final profile = profileSnapshot.data?.data() ?? {};
          final activity = activityFromString(profile['activity'] as String?);
          final availability =
              availabilityFromString(profile['availability'] as String?);
          return RefreshIndicator(
            onRefresh: () => UserRepository.instance.resolvePendingFriends(uid),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _MyStatusCard(
                  activity: activity,
                  availability: availability,
                  automationOn: _automationOn,
                  onActivityChanged: (value) async {
                    await UserRepository.instance.updateStatus(
                      uid: uid,
                      activity: value,
                    );
                  },
                  onAvailabilityChanged: (value) async {
                    await UserRepository.instance.updateStatus(
                      uid: uid,
                      availability: value,
                    );
                  },
                  onAutomationChanged: (value) =>
                      _toggleAutomation(value, activity),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Text(
                      'החברים שלי',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AddFriendsScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('הוסף'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: UserRepository.instance.friendsStream(uid),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final docs = snapshot.data!.docs;
                    if (docs.isEmpty) {
                      return const Card(
                        child: Padding(
                          padding: EdgeInsets.all(22),
                          child: Text(
                            'עדיין אין חברים. לחץ "הוסף" ובחר מתוך אנשי הקשר.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    return Column(
                      children: docs
                          .map((doc) => _FriendTile(friend: doc.data()))
                          .toList(),
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PhoneSetupDialog extends StatefulWidget {
  const _PhoneSetupDialog({required this.initialPhone});

  final String initialPhone;

  @override
  State<_PhoneSetupDialog> createState() => _PhoneSetupDialogState();
}

class _PhoneSetupDialogState extends State<_PhoneSetupDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPhone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (!UserRepository.instance.isValidPhone(value)) {
      setState(() => _error = 'נא להזין מספר טלפון תקין');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('מספר הטלפון שלי'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'המספר משמש רק כדי לזהות חברים שכבר שמרו אותך באנשי הקשר. '
            'אם המספר שמופיע אינו נכון, אפשר להחליף אותו.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.phone,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: 'מספר טלפון',
              hintText: '050-1234567',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('לא עכשיו'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('שמור'),
        ),
      ],
    );
  }
}

class _MyStatusCard extends StatelessWidget {
  const _MyStatusCard({
    required this.activity,
    required this.availability,
    required this.automationOn,
    required this.onActivityChanged,
    required this.onAvailabilityChanged,
    required this.onAutomationChanged,
  });

  final ActivityStatus activity;
  final AvailabilityStatus availability;
  final bool automationOn;
  final ValueChanged<ActivityStatus> onActivityChanged;
  final ValueChanged<AvailabilityStatus> onAvailabilityChanged;
  final ValueChanged<bool> onAutomationChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'המצב שלי',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ActivityStatus>(
              initialValue: activity,
              decoration: const InputDecoration(
                labelText: 'מה אני עושה עכשיו?',
                border: OutlineInputBorder(),
              ),
              items: ActivityStatus.values
                  .map(
                    (status) => DropdownMenuItem(
                      value: status,
                      child: Text('${status.emoji}  ${status.label}'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) onActivityChanged(value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<AvailabilityStatus>(
              initialValue: availability,
              decoration: const InputDecoration(
                labelText: 'האם נוח לדבר?',
                border: OutlineInputBorder(),
              ),
              items: AvailabilityStatus.values
                  .map(
                    (status) => DropdownMenuItem(
                      value: status,
                      child: Text('${status.emoji}  ${status.label}'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) onAvailabilityChanged(value);
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: automationOn,
              onChanged: onAutomationChanged,
              title: const Text('זיהוי אוטומטי'),
              subtitle: const Text('נסיעה לפי מהירות + אזורי בית/עבודה/כלב'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({required this.friend});

  final Map<String, dynamic> friend;

  @override
  Widget build(BuildContext context) {
    final name = friend['contactName'] as String? ?? 'חבר';
    final friendUid = friend['friendUid'] as String?;
    if (friendUid == null || friendUid.isEmpty) {
      return Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
          title: Text(name),
          subtitle: const Text('עדיין לא התקין/ה את האפליקציה'),
          trailing: IconButton(
            tooltip: 'שלח הזמנה',
            onPressed: () => ContactInviteService.instance.shareInvite(
              contactName: name,
            ),
            icon: const Icon(Icons.send_outlined),
          ),
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: UserRepository.instance.profileStream(friendUid),
      builder: (context, snapshot) {
        final profile = snapshot.data?.data();
        if (profile == null) {
          return Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(name),
              subtitle: const Text('טוען מצב...'),
            ),
          );
        }
        final activity = activityFromString(profile['activity'] as String?);
        final availability =
            availabilityFromString(profile['availability'] as String?);
        return Card(
          child: ListTile(
            leading: CircleAvatar(
              child: Text(activity.emoji),
            ),
            title: Text(profile['displayName'] as String? ?? name),
            subtitle: Text('${activity.label}  •  ${availability.label}'),
            trailing: Text(
              availability.emoji,
              style: const TextStyle(fontSize: 22),
            ),
          ),
        );
      },
    );
  }
}
