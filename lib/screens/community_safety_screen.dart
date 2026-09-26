import 'package:flutter/material.dart';

import '../services/user_repository.dart';

class CommunityTermsGate extends StatefulWidget {
  const CommunityTermsGate({
    super.key,
    required this.uid,
    required this.child,
  });

  final String uid;
  final Widget child;

  @override
  State<CommunityTermsGate> createState() => _CommunityTermsGateState();
}

class _CommunityTermsGateState extends State<CommunityTermsGate> {
  late Future<bool> _accepted;

  @override
  void initState() {
    super.initState();
    _accepted = UserRepository.instance.hasAcceptedCommunityTerms(widget.uid);
  }

  void _reload() {
    setState(() {
      _accepted = UserRepository.instance.hasAcceptedCommunityTerms(widget.uid);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _accepted,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == true) return widget.child;
        return CommunityTermsScreen(
          uid: widget.uid,
          onAccepted: _reload,
        );
      },
    );
  }
}

class CommunityTermsScreen extends StatefulWidget {
  const CommunityTermsScreen({
    super.key,
    required this.uid,
    this.onAccepted,
    this.readOnly = false,
  });

  final String uid;
  final VoidCallback? onAccepted;
  final bool readOnly;

  @override
  State<CommunityTermsScreen> createState() => _CommunityTermsScreenState();
}

class _CommunityTermsScreenState extends State<CommunityTermsScreen> {
  bool _agreed = false;
  bool _saving = false;

  Future<void> _accept() async {
    if (!_agreed || _saving) return;
    setState(() => _saving = true);
    try {
      await UserRepository.instance.acceptCommunityTerms(widget.uid);
      widget.onAccepted?.call();
      if (widget.readOnly && mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן לשמור את האישור: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.readOnly
          ? AppBar(title: const Text('כללי קהילה ותנאי שימוש'))
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.verified_user_outlined, size: 58),
                  const SizedBox(height: 16),
                  Text(
                    'כללי הקהילה של Matzav',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 20),
                  const _TermsCard(
                    title: 'אפס סובלנות לתוכן פוגעני ולהתנהגות פוגענית',
                    text:
                        'אין להשתמש ב־Matzav להטרדה, איומים, שנאה, תוכן מיני '
                        'פוגעני, התחזות, ספאם או כל שימוש בלתי חוקי. חשבון '
                        'שמפר את הכללים עשוי להיחסם או להימחק.',
                  ),
                  const _TermsCard(
                    title: 'מה משותף עם חברים',
                    text:
                        'Matzav משתפת עם חברים שאישרת את שם הפרופיל ואת '
                        'סטטוס הפעילות והזמינות. אין באפליקציה פוסטים ציבוריים '
                        'או שדה חופשי לפרסום תוכן לציבור.',
                  ),
                  const _TermsCard(
                    title: 'דיווח וחסימה',
                    text:
                        'מתפריט האפשרויות של חבר אפשר לדווח על משתמש או לחסום '
                        'אותו. חסימה מסירה את הקשר ומונעת יצירה מחדש של הקשר '
                        'כל עוד החסימה פעילה.',
                  ),
                  const _TermsCard(
                    title: 'שמירה על הפרטיות',
                    text:
                        'אין לפרסם או לשתף מידע אישי של אדם אחר ללא רשות. '
                        'מיקום מדויק אינו מוצג לחברים; הוא משמש רק לאוטומציה '
                        'של הסטטוס בהתאם להגדרות המשתמש.',
                  ),
                  if (!widget.readOnly) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: _agreed,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _agreed = value == true),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'קראתי ואני מסכים/ה לכללי הקהילה ולתנאי השימוש.',
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _agreed && !_saving ? _accept : null,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: const Text('אישור והמשך'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TermsCard extends StatelessWidget {
  const _TermsCard({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 6),
            Text(text),
          ],
        ),
      ),
    );
  }
}

class SupportContactScreen extends StatefulWidget {
  const SupportContactScreen({super.key, required this.uid});

  final String uid;

  @override
  State<SupportContactScreen> createState() => _SupportContactScreenState();
}

class _SupportContactScreenState extends State<SupportContactScreen> {
  final _message = TextEditingController();
  String _category = 'support';
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await UserRepository.instance.sendSupportMessage(
        uid: widget.uid,
        category: _category,
        message: text,
      );
      if (!mounted) return;
      _message.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('הפנייה נשלחה. תודה — נחזור אליך בהקדם האפשרי.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן לשלוח את הפנייה: $error')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('צור קשר עם התמיכה')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'אפשר לפנות אלינו בנוגע לתקלה, פרטיות, בטיחות או כל שאלה אחרת.',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(
              labelText: 'נושא',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'support', child: Text('תמיכה טכנית')),
              DropdownMenuItem(value: 'safety', child: Text('בטיחות / פגיעה')),
              DropdownMenuItem(value: 'privacy', child: Text('פרטיות')),
              DropdownMenuItem(value: 'other', child: Text('אחר')),
            ],
            onChanged: _sending
                ? null
                : (value) => setState(() => _category = value ?? 'support'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _message,
            enabled: !_sending,
            minLines: 5,
            maxLines: 10,
            maxLength: 1500,
            decoration: const InputDecoration(
              labelText: 'הודעה',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: const Text('שלח'),
          ),
        ],
      ),
    );
  }
}
