import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateDecision {
  const AppUpdateDecision({
    required this.updateAvailable,
    required this.forceUpdate,
    required this.currentBuild,
    required this.latestBuild,
    required this.storeUrl,
    this.message,
    this.playUpdateInfo,
  });

  final bool updateAvailable;
  final bool forceUpdate;
  final int currentBuild;
  final int latestBuild;
  final String storeUrl;
  final String? message;
  final AppUpdateInfo? playUpdateInfo;
}

class AppUpdateService {
  AppUpdateService._();
  static final instance = AppUpdateService._();

  static const _defaultAndroidUrl =
      'https://play.google.com/store/apps/details?id=com.mikron30.matzav';

  Future<AppUpdateDecision> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

    int latestBuild = currentBuild;
    int minimumBuild = 0;
    String storeUrl = _defaultAndroidUrl;
    String? message;

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('version')
          .get();
      final data = snapshot.data();
      if (data != null) {
        latestBuild = (data['latestBuild'] as num?)?.toInt() ?? currentBuild;
        minimumBuild = (data['minimumBuild'] as num?)?.toInt() ?? 0;
        message = data['message'] as String?;

        if (Platform.isAndroid) {
          storeUrl = (data['androidUrl'] as String?)?.trim().isNotEmpty == true
              ? (data['androidUrl'] as String).trim()
              : _defaultAndroidUrl;
        }
      }
    } catch (_) {
      // Firestore configuration is optional. Google Play can still report
      // whether an update is available on Android.
    }

    AppUpdateInfo? playInfo;
    bool playSaysUpdateAvailable = false;

    if (Platform.isAndroid) {
      try {
        playInfo = await InAppUpdate.checkForUpdate();
        playSaysUpdateAvailable =
            playInfo.updateAvailability == UpdateAvailability.updateAvailable;
        final availableVersion = playInfo.availableVersionCode;
        if (availableVersion != null && availableVersion > latestBuild) {
          latestBuild = availableVersion;
        }
      } catch (_) {
        // This can fail for debug/sideloaded builds. The Firestore check above
        // remains enough for release builds when app_config/version exists.
      }
    }

    final updateAvailable =
        currentBuild < latestBuild || playSaysUpdateAvailable;
    final forceUpdate = currentBuild < minimumBuild;

    return AppUpdateDecision(
      updateAvailable: updateAvailable,
      forceUpdate: forceUpdate,
      currentBuild: currentBuild,
      latestBuild: latestBuild,
      storeUrl: storeUrl,
      message: message,
      playUpdateInfo: playInfo,
    );
  }

  Future<void> startUpdate(AppUpdateDecision decision) async {
    if (Platform.isAndroid) {
      final info = decision.playUpdateInfo;
      if (info != null &&
          info.updateAvailability == UpdateAvailability.updateAvailable &&
          info.immediateUpdateAllowed) {
        try {
          await InAppUpdate.performImmediateUpdate();
          return;
        } catch (_) {
          // Fall through to the Play Store page.
        }
      }
    }

    final uri = Uri.tryParse(decision.storeUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate> {
  AppUpdateDecision? _decision;
  bool _checking = true;
  bool _optionalDialogShown = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (mounted) setState(() => _checking = true);
    try {
      final decision = await AppUpdateService.instance.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _decision = decision;
        _checking = false;
      });

      if (decision.updateAvailable && !decision.forceUpdate) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showOptionalUpdate(decision);
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _checking = false);
    }
  }

  Future<void> _showOptionalUpdate(AppUpdateDecision decision) async {
    if (_optionalDialogShown) return;
    _optionalDialogShown = true;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.system_update_alt),
        title: const Text('יש גרסה חדשה'),
        content: Text(
          decision.message?.trim().isNotEmpty == true
              ? decision.message!.trim()
              : 'קיימת גרסה חדשה של Matzav. מומלץ לעדכן עכשיו.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('אחר כך'),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await AppUpdateService.instance.startUpdate(decision);
            },
            icon: const Icon(Icons.download_outlined),
            label: const Text('עדכן עכשיו'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final decision = _decision;

    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (decision != null && decision.updateAvailable && decision.forceUpdate) {
      return _RequiredUpdateScreen(decision: decision, onRetry: _check);
    }

    return widget.child;
  }
}

class _RequiredUpdateScreen extends StatelessWidget {
  const _RequiredUpdateScreen({
    required this.decision,
    required this.onRetry,
  });

  final AppUpdateDecision decision;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.system_update_alt,
                    size: 72,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'נדרש עדכון של Matzav',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    decision.message?.trim().isNotEmpty == true
                        ? decision.message!.trim()
                        : 'הגרסה שמותקנת אצלך ישנה מדי. נא לעדכן לגרסה האחרונה כדי להמשיך.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () =>
                          AppUpdateService.instance.startUpdate(decision),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('עדכן עכשיו'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('כבר עדכנתי — בדוק שוב'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
