import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'firebase_options.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_update_service.dart';
import 'services/premium_service.dart';
import 'services/user_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StartupDiagnosticApp());
}

class StartupDiagnosticApp extends StatefulWidget {
  const StartupDiagnosticApp({super.key});

  @override
  State<StartupDiagnosticApp> createState() => _StartupDiagnosticAppState();
}

class _StartupDiagnosticAppState extends State<StartupDiagnosticApp> {
  String _stage = '1/5 Flutter started';
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));

    try {
      _setStage('2/5 Initializing Firebase');
      await Firebase.initializeApp()
          .timeout(const Duration(seconds: 15));

      _setStage('3/5 Loading local settings');
      await ThemeService.instance
          .initialize()
          .timeout(const Duration(seconds: 10));

      _setStage('4/5 Starting Premium service');
      final premiumService = PremiumService.instance;
      unawaited(premiumService.initialize());

      _setStage('5/5 Starting Matzav');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;
      setState(() => _ready = true);
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() {
        _error = '$error\n\n${stackTrace.toString().split('\n').take(8).join('\n')}';
      });
    }
  }

  void _setStage(String value) {
    if (!mounted) return;
    setState(() {
      _stage = value;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return const MatzavApp();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.health_and_safety_outlined, size: 72),
                  const SizedBox(height: 20),
                  const Text(
                    'Matzav startup diagnostic',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Build 53',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _stage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18),
                  ),
                  if (_error == null) ...[
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(),
                  ] else ...[
                    const SizedBox(height: 24),
                    const Text(
                      'STARTUP ERROR',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      _error!,
                      textAlign: TextAlign.left,
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

class MatzavApp extends StatelessWidget {
  const MatzavApp({super.key});

  ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      listTileTheme: ListTileThemeData(
        textColor: scheme.onSurface,
        iconColor: scheme.onSurfaceVariant,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brightness == Brightness.dark
            ? scheme.surfaceContainerHighest
            : scheme.surfaceContainerLowest,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ThemeService.instance,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Matzav',
          locale: const Locale('he'),
          supportedLocales: const [Locale('he'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          themeMode: ThemeService.instance.themeMode,
          home: const AppUpdateGate(child: AuthGate()),
        );
      },
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snapshot.data;
        if (user == null) return const AuthScreen();
        unawaited(PremiumService.instance.initialize(uid: user.uid));
        return FutureBuilder<void>(
          future: UserRepository.instance.ensureUserProfile(user),
          builder: (context, ensureSnapshot) {
            if (ensureSnapshot.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return const HomeScreen();
          },
        );
      },
    );
  }
}
