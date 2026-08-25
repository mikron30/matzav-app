import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/friend_access_policy.dart';
import '../models/status_models.dart';
import '../services/auth_service.dart';
import '../services/call_wait_service.dart';
import '../services/automatic_status_service.dart';
import '../services/contact_invite_service.dart';
import '../services/direct_call_service.dart';
import '../services/location_status_service.dart';
import '../services/phone_hint_service.dart';
import '../services/premium_service.dart';
import '../services/status_timer_service.dart';
import '../services/user_repository.dart';
import '../widgets/premium_banner.dart';
import 'add_friends_screen.dart';
import 'premium_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _automationOn = true;
  bool _automationRestoreStarted = false;
  bool _phoneSetupChecked = false;
  int _statusUiRevision = 0;
  StreamSubscription<String>? _callWaitMessageSubscription;

  String get uid => FirebaseAuth.instance.currentUser!.uid;

  @override
  void initState() {
    super.initState();
    _restoreAutomationPreference();
    UserRepository.instance.syncFriendRelationships(uid);
    _callWaitMessageSubscription = CallWaitService.instance.foregroundMessages
        .listen((message) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        });
    unawaited(CallWaitService.instance.initializeForUser(uid));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensurePhoneIdentity();
      _restoreAutomation();
    });
  }

  @override
  void dispose() {
    StatusTimerService.instance.cancelLocalTimers();
    unawaited(_callWaitMessageSubscription?.cancel());
    unawaited(CallWaitService.instance.dispose());
    super.dispose();
  }

  Future<void> _restoreAutomationPreference() async {
    final prefs = await SharedPreferences.getInstance();

    // First installation: automatic detection is ON.
    // Afterwards, remember the user's last choice.
    final enabled = prefs.getBool('matzav_automation_enabled_v25') ?? true;

    if (!mounted) return;
    setState(() => _automationOn = enabled);

    if (!enabled) return;

    final profile = await FirebaseFirestore.instance
        .collection('profiles')
        .doc(uid)
        .get();

    final currentActivity = activityFromString(
      profile.data()?['activity'] as String?,
    );

    await _toggleAutomation(true, currentActivity);
  }

  Future<void> _ensurePhoneIdentity() async {
    if (_phoneSetupChecked) return;
    _phoneSetupChecked = true;

    try {
      final existingPhone = await UserRepository.instance.getRegisteredPhone(
        uid,
      );
      if (existingPhone != null && existingPhone.isNotEmpty) return;

      final hintedPhone = await PhoneHintService.instance
          .requestPhoneNumberHint();
      if (!mounted) return;

      final selectedPhone = await showDialog<String>(
        context: context,
        builder: (context) =>
            _PhoneSetupDialog(initialPhone: hintedPhone ?? ''),
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

  Future<void> _restoreAutomation() async {
    if (_automationRestoreStarted) return;
    _automationRestoreStarted = true;

    final enabled = await LocationStatusService.instance.isAutomationEnabled();
    if (!enabled || !mounted) return;

    try {
      final snapshot = await UserRepository.instance.profileStream(uid).first;
      final activity = activityFromString(
        snapshot.data()?['activity'] as String?,
      );
      await LocationStatusService.instance.start(
        uid: uid,
        currentActivity: activity,
        remember: false,
      );
      await AutomaticStatusService.instance.start(uid: uid);
      if (mounted) setState(() => _automationOn = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _automationOn = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'הזיהוי האוטומטי שמור, אבל לא ניתן להפעיל אותו כרגע: $e',
          ),
        ),
      );
    }
  }

  Future<void> _toggleAutomation(
    bool value,
    ActivityStatus currentActivity,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      if (value) {
        await LocationStatusService.instance.start(
          uid: uid,
          currentActivity: currentActivity,
        );
        await AutomaticStatusService.instance.start(uid: uid);
      } else {
        await AutomaticStatusService.instance.stop();
        await LocationStatusService.instance.disable();
      }
      await prefs.setBool('matzav_automation_enabled_v25', value);
      if (mounted) setState(() => _automationOn = value);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('האוטומציה לא הופעלה: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Matzav'),
        actions: [
          IconButton(
            tooltip: 'Matzav Premium',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => PremiumScreen(uid: uid))),
            icon: const Icon(Icons.workspace_premium_outlined),
          ),
          IconButton(
            tooltip: 'הגדרות',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'התנתק',
            onPressed: () async {
              await AutomaticStatusService.instance.stop();
              await LocationStatusService.instance.disable();
              await AuthService.instance.signOut();
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: UserRepository.instance.profileStream(uid),
        builder: (context, profileSnapshot) {
          final profile = profileSnapshot.data?.data() ?? <String, dynamic>{};
          final activity = StatusTimerService.effectiveActivity(profile);
          final availability = StatusTimerService.effectiveAvailability(
            profile,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(
              StatusTimerService.instance.syncAndSchedule(uid, profile),
            );
          });
          return RefreshIndicator(
            onRefresh: () =>
                UserRepository.instance.syncFriendRelationships(uid),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _MyStatusCard(
                  key: ValueKey(_statusUiRevision),
                  activity: activity,
                  availability: availability,
                  automationOn: _automationOn,
                  onActivityChanged: (value) async {
                    if (value == ActivityStatus.meeting) {
                      final end = await showDialog<DateTime>(
                        context: context,
                        builder: (_) => const _StatusTimerDialog(
                          title: 'כמה זמן להשאיר מצב פגישה?',
                        ),
                      );
                      if (end == null) {
                        if (mounted) {
                          setState(() => _statusUiRevision++);
                        }
                        return;
                      }
                      await StatusTimerService.instance.startActivityTimer(
                        uid: uid,
                        previous: activity,
                        endsAt: end,
                      );
                      if (_automationOn) {
                        LocationStatusService.instance.noteManualActivity(
                          ActivityStatus.meeting,
                        );
                      }
                    } else {
                      await StatusTimerService.instance.setManualActivity(
                        uid: uid,
                        activity: value,
                      );
                      if (_automationOn &&
                          value != ActivityStatus.onCall &&
                          value != ActivityStatus.sleeping) {
                        LocationStatusService.instance.noteManualActivity(
                          value,
                        );
                      }
                    }
                    if (mounted) setState(() => _statusUiRevision++);
                  },
                  onAvailabilityChanged: (value) async {
                    if (value == AvailabilityStatus.doNotDisturb) {
                      final end = await showDialog<DateTime>(
                        context: context,
                        builder: (_) => const _StatusTimerDialog(
                          title: 'כמה זמן להשאיר נא לא להפריע?',
                        ),
                      );
                      if (end == null) {
                        if (mounted) {
                          setState(() => _statusUiRevision++);
                        }
                        return;
                      }
                      await StatusTimerService.instance.startAvailabilityTimer(
                        uid: uid,
                        previous: availability,
                        endsAt: end,
                      );
                    } else {
                      await StatusTimerService.instance.setManualAvailability(
                        uid: uid,
                        availability: value,
                      );
                    }
                    if (mounted) setState(() => _statusUiRevision++);
                  },
                  onAutomationChanged: (value) =>
                      _toggleAutomation(value, activity),
                ),
                const SizedBox(height: 22),
                // MATZAV_V25_FRIENDS_THEME
                ListTileTheme(
                  data: const ListTileThemeData(
                    dense: true,
                    visualDensity: VisualDensity(horizontal: -2, vertical: -2),
                    contentPadding: EdgeInsetsDirectional.fromSTEB(8, 0, 4, 0),
                    minLeadingWidth: 36,
                    horizontalTitleGap: 8,
                    minVerticalPadding: 2,
                    titleTextStyle: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    subtitleTextStyle: TextStyle(fontSize: 11.5, height: 1.15),
                  ),
                  child: _FriendsSection(uid: uid),
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: const PremiumAwareBanner(),
    );
  }
}

class _FriendsSection extends StatelessWidget {
  const _FriendsSection({required this.uid});

  final String uid;

  Future<void> _openAddFriends(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AddFriendsScreen()));
  }

  Future<void> _openPremium(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PremiumScreen(uid: uid)));
  }

  Future<void> _removeFriend(
    BuildContext context, {
    required String friendId,
    required String friendName,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('הסרת חבר'),
        content: Text('להסיר את $friendName מרשימת החברים?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ביטול'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('הסר'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await UserRepository.instance.removeFriend(
        ownerUid: uid,
        friendId: friendId,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$friendName הוסר מרשימת החברים.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('לא ניתן להסיר את החבר: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: UserRepository.instance.friendsStream(uid),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('לא ניתן לטעון את רשימת החברים.'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;
        return AnimatedBuilder(
          animation: PremiumService.instance,
          builder: (context, _) {
            final isPremium = PremiumService.instance.isPremium;
            final atFreeLimit =
                !isPremium && docs.length >= FriendAccessPolicy.freeFriendLimit;
            return Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'החברים שלי',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            isPremium
                                ? '${docs.length} חברים • Premium'
                                : '${docs.length} מתוך ${FriendAccessPolicy.freeFriendLimit} בחינם',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: atFreeLimit
                          ? () => _openPremium(context)
                          : () => _openAddFriends(context),
                      icon: Icon(
                        atFreeLimit
                            ? Icons.workspace_premium
                            : Icons.person_add_alt_1,
                      ),
                      label: Text(atFreeLimit ? 'Premium' : 'הוסף'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (docs.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(22),
                      child: Text(
                        'עדיין אין חברים. לחץ "הוסף" ובחר מתוך אנשי הקשר.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  ...docs.map(
                    (doc) => _FriendTile(
                      ownerUid: uid,
                      friend: doc.data(),
                      onRemove: (name) => _removeFriend(
                        context,
                        friendId: doc.id,
                        friendName: name,
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
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
        FilledButton(onPressed: _save, child: const Text('שמור')),
      ],
    );
  }
}

class _StatusTimerDialog extends StatefulWidget {
  const _StatusTimerDialog({required this.title});

  final String title;

  @override
  State<_StatusTimerDialog> createState() => _StatusTimerDialogState();
}

class _StatusTimerDialogState extends State<_StatusTimerDialog> {
  final _hoursController = TextEditingController(text: '1');
  final _minutesController = TextEditingController(text: '0');
  bool _useEndTime = false;
  DateTime? _selectedEnd;
  String? _error;

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  Future<void> _pickEndTime() async {
    final now = DateTime.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: 'בחר שעת סיום',
    );
    if (picked == null || !mounted) return;

    var end = DateTime(
      now.year,
      now.month,
      now.day,
      picked.hour,
      picked.minute,
    );
    if (!end.isAfter(now)) {
      end = end.add(const Duration(days: 1));
    }
    if (end.difference(now) > const Duration(days: 1)) {
      setState(() => _error = 'אפשר לבחור עד 24 שעות קדימה.');
      return;
    }
    setState(() {
      _selectedEnd = end;
      _error = null;
    });
  }

  void _save() {
    final now = DateTime.now();
    DateTime? end;

    if (_useEndTime) {
      end = _selectedEnd;
      if (end == null) {
        setState(() => _error = 'בחר שעת סיום.');
        return;
      }
    } else {
      final hours = int.tryParse(_hoursController.text.trim()) ?? -1;
      final minutes = int.tryParse(_minutesController.text.trim()) ?? -1;
      if (hours < 0 || minutes < 0 || minutes > 59) {
        setState(() => _error = 'הזן שעות ודקות תקינות.');
        return;
      }
      final totalMinutes = hours * 60 + minutes;
      if (totalMinutes < 1 || totalMinutes > 24 * 60) {
        setState(() => _error = 'הטיימר חייב להיות בין דקה אחת ל־24 שעות.');
        return;
      }
      end = now.add(Duration(minutes: totalMinutes));
    }

    final duration = end.difference(now);
    if (duration <= Duration.zero || duration > const Duration(days: 1)) {
      setState(() => _error = 'אפשר לבחור זמן של עד 24 שעות בלבד.');
      return;
    }

    Navigator.of(context).pop(end);
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final tomorrow = value.day != DateTime.now().day ? ' מחר' : '';
    return '$hour:$minute$tomorrow';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.timer_outlined),
                  label: Text('שעות ודקות'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.schedule),
                  label: Text('שעת סיום'),
                ),
              ],
              selected: {_useEndTime},
              onSelectionChanged: (selection) {
                setState(() {
                  _useEndTime = selection.first;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: 18),
            if (!_useEndTime)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _hoursController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'שעות',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _minutesController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'דקות',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              )
            else
              OutlinedButton.icon(
                onPressed: _pickEndTime,
                icon: const Icon(Icons.access_time),
                label: Text(
                  _selectedEnd == null
                      ? 'בחר שעת סיום'
                      : 'עד ${_formatTime(_selectedEnd!)}',
                ),
              ),
            const SizedBox(height: 10),
            const Text(
              'מקסימום: 24 שעות. בסיום המצב יחזור אוטומטית למצב שהיה קודם.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ביטול'),
        ),
        FilledButton(onPressed: _save, child: const Text('הפעל טיימר')),
      ],
    );
  }
}

class _MyStatusCard extends StatelessWidget {
  const _MyStatusCard({
    super.key,
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
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
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
              subtitle: const Text(
                'נסיעה + שיחה + שינה + אזורי בית/עבודה/כלב • פועל גם ברקע',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendTile extends StatefulWidget {
  const _FriendTile({
    required this.ownerUid,
    required this.friend,
    required this.onRemove,
  });

  final String ownerUid;
  final Map<String, dynamic> friend;
  final ValueChanged<String> onRemove;

  @override
  State<_FriendTile> createState() => _FriendTileState();
}

class _FriendTileState extends State<_FriendTile> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String? get _phoneNumber {
    final direct = widget.friend['phone'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct.trim();
    }

    final phones = widget.friend['phones'];
    if (phones is List) {
      for (final value in phones) {
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
    }
    return null;
  }

  Future<void> _callFriend(BuildContext context, String displayName) async {
    final phone = _phoneNumber;
    if (phone == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('אין מספר טלפון זמין עבור $displayName')),
      );
      return;
    }

    final started = await DirectCallService.instance.callNumber(phone);
    if (!started && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן להתחיל שיחה עם $displayName')),
      );
    }
  }

  Widget _callIcon() {
    if (_phoneNumber == null) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsetsDirectional.only(end: 4),
      child: Icon(Icons.call_outlined, size: 20),
    );
  }

  String _timerText(DateTime end) {
    final remaining = end.difference(DateTime.now());
    if (remaining <= Duration.zero) return 'הסתיימה';
    final totalMinutes =
        remaining.inMinutes + (remaining.inSeconds % 60 == 0 ? 0 : 1);
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    final endHour = end.hour.toString().padLeft(2, '0');
    final endMinute = end.minute.toString().padLeft(2, '0');
    final left = hours > 0 ? '$hoursש $minutesד' : '$minutesד';
    return 'עד $endHour:$endMinute • נשאר $left';
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.friend['contactName'] as String? ?? 'חבר';
    final friendUid = widget.friend['friendUid'] as String?;
    final storedPhoto = widget.friend['contactPhoto'];
    final contactPhoto = storedPhoto is Blob ? storedPhoto.bytes : null;

    if (friendUid == null || friendUid.isEmpty) {
      return Card(
        child: ListTile(
          onTap: () => _callFriend(context, name),
          leading: _FriendAvatar(name: name, contactPhoto: contactPhoto),
          title: Text(name),
          subtitle: Text(
            _phoneNumber == null
                ? 'עדיין לא התקין/ה את האפליקציה'
                : 'עדיין לא התקין/ה את האפליקציה • לחץ להתקשר',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _callIcon(),
              IconButton(
                tooltip: 'שלח הזמנה',
                onPressed: () => ContactInviteService.instance.shareInvite(
                  contactName: name,
                ),
                icon: const Icon(Icons.send_outlined),
              ),
              _FriendMenu(onRemove: () => widget.onRemove(name)),
            ],
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
              onTap: () => _callFriend(context, name),
              leading: _FriendAvatar(name: name, contactPhoto: contactPhoto),
              title: Text(name),
              subtitle: Text(
                _phoneNumber == null
                    ? 'טוען מצב...'
                    : 'טוען מצב... • לחץ להתקשר',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _callIcon(),
                  _FriendMenu(onRemove: () => widget.onRemove(name)),
                ],
              ),
            ),
          );
        }

        final activity = StatusTimerService.effectiveActivity(profile);
        final availability = StatusTimerService.effectiveAvailability(profile);
        final displayName = profile['displayName'] as String? ?? name;
        final photoUrl = profile['photoUrl'] as String?;
        final activityTimerEnd = StatusTimerService.activeActivityTimerEnd(
          profile,
        );
        final availabilityTimerEnd =
            StatusTimerService.activeAvailabilityTimerEnd(profile);
        final hasTimer =
            activityTimerEnd != null || availabilityTimerEnd != null;
        final onCall = activity == ActivityStatus.onCall;

        return Card(
          child: ListTile(
            onTap: () => _callFriend(context, displayName),
            isThreeLine: onCall || hasTimer,
            leading: _FriendAvatar(
              name: displayName,
              photoUrl: photoUrl,
              contactPhoto: contactPhoto,
              activityEmoji: activity.emoji,
            ),
            title: Text(displayName),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _phoneNumber == null
                      ? '${activity.label}  •  ${availability.label}'
                      : '${activity.label}  •  ${availability.label}  •  לחץ להתקשר',
                ),
                if (activityTimerEnd != null)
                  Text(
                    '⏱ פגישה ${_timerText(activityTimerEnd)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (availabilityTimerEnd != null)
                  Text(
                    '⏱ נא לא להפריע ${_timerText(availabilityTimerEnd)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (onCall)
                  _CallWaitButton(
                    requesterUid: widget.ownerUid,
                    targetUid: friendUid,
                    targetName: displayName,
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _callIcon(),
                Text(availability.emoji, style: const TextStyle(fontSize: 22)),
                _FriendMenu(onRemove: () => widget.onRemove(displayName)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CallWaitButton extends StatelessWidget {
  const _CallWaitButton({
    required this.requesterUid,
    required this.targetUid,
    required this.targetName,
  });

  final String requesterUid;
  final String targetUid;
  final String targetName;

  Future<void> _startWaiting(BuildContext context) async {
    try {
      final ok = await CallWaitService.instance.waitForCallEnd(
        requesterUid: requesterUid,
        targetUid: targetUid,
        targetName: targetName,
      );
      if (!context.mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('השיחה של $targetName כבר הסתיימה.')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('תקבל התראה כאשר השיחה של $targetName תסתיים.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן להפעיל המתנה לסיום השיחה: $e')),
      );
    }
  }

  Future<void> _cancelWaiting(BuildContext context) async {
    try {
      await CallWaitService.instance.cancelWait(
        requesterUid: requesterUid,
        targetUid: targetUid,
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('לא ניתן לבטל את ההמתנה: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: CallWaitService.instance.waitingStream(
        requesterUid: requesterUid,
        targetUid: targetUid,
      ),
      builder: (context, snapshot) {
        final waiting = snapshot.data ?? false;
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () =>
                waiting ? _cancelWaiting(context) : _startWaiting(context),
            icon: Icon(
              waiting
                  ? Icons.notifications_off_outlined
                  : Icons.notifications_active_outlined,
              size: 18,
            ),
            label: Text(waiting ? 'בטל המתנה לסיום השיחה' : 'המתן לסיום השיחה'),
          ),
        );
      },
    );
  }
}

class _FriendMenu extends StatelessWidget {
  const _FriendMenu({required this.onRemove});

  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'אפשרויות חבר',
      onSelected: (value) {
        if (value == 'remove') onRemove();
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'remove',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_remove_outlined),
            title: Text('הסר חבר'),
          ),
        ),
      ],
    );
  }
}

class _FriendAvatar extends StatelessWidget {
  const _FriendAvatar({
    required this.name,
    this.photoUrl,
    this.contactPhoto,
    this.activityEmoji,
  });

  final String name;
  final String? photoUrl;
  final Uint8List? contactPhoto;
  final String? activityEmoji;

  @override
  Widget build(BuildContext context) {
    final validPhotoUrl = photoUrl?.trim().isNotEmpty == true ? photoUrl : null;
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first;

    return SizedBox.square(
      dimension: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ClipOval(
              child: validPhotoUrl == null
                  ? _fallbackImage(context, initial)
                  : Image.network(
                      validPhotoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _fallbackImage(context, initial),
                    ),
            ),
          ),
          if (activityEmoji != null)
            PositionedDirectional(
              end: -4,
              bottom: -4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Text(
                    activityEmoji!,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _fallbackImage(BuildContext context, String initial) {
    final photo = contactPhoto;
    if (photo != null && photo.isNotEmpty) {
      return Image.memory(
        photo,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            _initialAvatar(context, initial),
      );
    }
    return _initialAvatar(context, initial);
  }

  Widget _initialAvatar(BuildContext context, String initial) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Center(
        child: Text(initial, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }
}
