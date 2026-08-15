import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/user_repository.dart';

const _internalTest = bool.fromEnvironment('MATZAV_INTERNAL_TEST');

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _register = false;

  Future<void> _run(Future<UserCredential> Function() action) async {
    setState(() => _busy = true);
    try {
      final result = await action();
      await UserRepository.instance.ensureUserProfile(result.user!);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message ?? e.code)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('שגיאה: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Matzav',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'יודעים מתי נוח להתקשר',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 32),
                  if (!_internalTest) ...[
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: 'אימייל',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'סיסמה',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              () => _register
                                  ? AuthService.instance.registerWithEmail(
                                      _email.text,
                                      _password.text,
                                    )
                                  : AuthService.instance.signInWithEmail(
                                      _email.text,
                                      _password.text,
                                    ),
                            ),
                      child: Text(
                        _register ? 'הרשמה באימייל' : 'כניסה באימייל',
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _register = !_register),
                      child: Text(
                        _register
                            ? 'כבר רשום? עבור לכניסה'
                            : 'חדש? עבור להרשמה',
                      ),
                    ),
                  ],
                  const Divider(height: 32),
                  if (_internalTest) ...[
                    const Text(
                      'Internal test: continue with Google using mikron30@gmail.com.',
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.ltr,
                    ),
                    const SizedBox(height: 12),
                  ],
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(AuthService.instance.signInWithGoogle),
                    icon: const Icon(Icons.account_circle_outlined),
                    label: const Text('המשך עם Google'),
                  ),
                  if (!_internalTest) const SizedBox(height: 10),
                  if (!_internalTest)
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const PhoneAuthScreen(),
                              ),
                            ),
                      icon: const Icon(Icons.phone_android),
                      label: const Text('המשך עם טלפון'),
                    ),
                  if (_busy) ...[
                    const SizedBox(height: 20),
                    const Center(child: CircularProgressIndicator()),
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

class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final _phone = TextEditingController(text: '+972');
  final _code = TextEditingController();
  String? _verificationId;
  bool _busy = false;

  Future<void> _finish(UserCredential credential) async {
    await UserRepository.instance.ensureUserProfile(credential.user!);
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _sendCode() async {
    setState(() => _busy = true);
    await AuthService.instance.sendPhoneCode(
      phone: _phone.text,
      onCodeSent: (id) {
        if (!mounted) return;
        setState(() {
          _verificationId = id;
          _busy = false;
        });
      },
      onAutoVerified: (credential) async {
        await _finish(credential);
      },
      onError: (error) {
        if (!mounted) return;
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
      },
    );
  }

  Future<void> _verify() async {
    final id = _verificationId;
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final credential = await AuthService.instance.verifySmsCode(
        verificationId: id,
        code: _code.text,
      );
      await _finish(credential);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message ?? e.code)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('כניסה עם טלפון')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'מספר כולל קידומת מדינה',
                hintText: '+972501234567',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_verificationId == null)
              FilledButton(
                onPressed: _busy ? null : _sendCode,
                child: const Text('שלח קוד SMS'),
              )
            else ...[
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'קוד אימות',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _verify,
                child: const Text('אמת והיכנס'),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }
}
