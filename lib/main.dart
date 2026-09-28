import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'firebase_options.dart';
import 'screens/auth_screen.dart';
import 'screens/community_safety_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_update_service.dart';
import 'services/premium_service.dart';
import 'services/user_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Render immediately. Previously Firebase/theme initialization happened
  // before runApp(), so any plugin/configuration error left iOS showing only
  // a completely blank white Flutter view with no way to diagnose or retry.
  runApp(const MatzavBootstrapApp());
}

class MatzavBootstrapApp extends StatefulWidget {
  const MatzavBootstrapApp({super.key});

  @override
  State<MatzavBootstrapApp> createState() => _MatzavBootstrapAppState();
}

class _MatzavBootstrapAppState extends State<MatzavBootstrapApp> {
  bool _ready = false;
  bool _starting = true;
  String _stage = 'מפעיל את Matzav…';
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    if (mounted) {
      setState(() {
        _starting = true;
        _error = null;
        _stage = 'מתחבר לשירותי האפליקציה…';
      });
    }

    try {
      try {
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
          // The iOS Xcode project does not bundle GoogleService-Info.plist as
          // an app resource. Initialize explicitly from FlutterFire options so
          // App Store/TestFlight installs do not depend on native plist lookup.
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.ios,
          ).timeout(const Duration(seconds: 12));
        } else {
          // Android already has its native Firebase configuration and should
          // keep using it to avoid the duplicate-[DEFAULT] issue seen before.
          await Firebase.initializeApp().timeout(const Duration(seconds: 12));
        }
      } on FirebaseException catch (error) {
        // If a native SDK already created [DEFAULT], use it rather than fail.
        if (error.code != 'duplicate-app') rethrow;
        Firebase.app();
      }

      if (mounted) {
        setState(() => _stage = 'טוען הגדרות…');
      }

      // Theme preferences are useful but must never prevent the app opening.
      try {
        await ThemeService.instance
            .initialize()
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // Continue with the default light theme.
      }

      // Store initialization is deliberately non-blocking.
      unawaited(PremiumService.instance.initialize());

      if (!mounted) return;
      setState(() {
        _ready = true;
        _starting = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return const MatzavApp();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Matzav',
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_outline, size: 72),
                    const SizedBox(height: 22),
                    const Text(
                      'Matzav',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (_starting) ...[
                      const CircularProgressIndicator(),
                      const SizedBox(height: 18),
                      Text(_stage, textAlign: TextAlign.center),
                    ] else ...[
                      const Icon(Icons.error_outline, size: 48),
                      const SizedBox(height: 14),
                      const Text(
                        'לא הצלחנו להשלים את הפעלת האפליקציה.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _error?.toString() ?? 'Startup error',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _bootstrap,
                        icon: const Icon(Icons.refresh),
                        label: const Text('נסה שוב'),
                      ),
                    ],
                  ],
                ),
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

            if (ensureSnapshot.hasError) {
              return _ProfileStartupError(
                error: ensureSnapshot.error,
              );
            }

            return CommunityTermsGate(
              uid: user.uid,
              child: const HomeScreen(),
            );
          },
        );
      },
    );
  }
}

class _ProfileStartupError extends StatelessWidget {
  const _ProfileStartupError({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 56),
                const SizedBox(height: 16),
                const Text(
                  'לא ניתן לטעון את החשבון כרגע.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  error?.toString() ?? 'Profile initialization error',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () async {
                    await FirebaseAuth.instance.signOut();
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('חזור למסך הכניסה'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
