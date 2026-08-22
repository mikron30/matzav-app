import 'dart:async';

import 'package:flutter/material.dart';

import '../services/premium_service.dart';

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({
    super.key,
    this.uid,
    this.hashedUid,
    this.premiumService,
  });

  /// A raw Firebase UID. [PremiumService] hashes it before sending it to a
  /// store. Alternatively, provide [hashedUid], but never both.
  final String? uid;
  final String? hashedUid;
  final PremiumService? premiumService;

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  late final PremiumService _premiumService;

  @override
  void initState() {
    super.initState();
    _premiumService = widget.premiumService ?? PremiumService.instance;
    unawaited(
      _premiumService.initialize(uid: widget.uid, hashedUid: widget.hashedUid),
    );
  }

  Future<void> _buy() async {
    await _premiumService.buyPremium(
      uid: widget.uid,
      hashedUid: widget.hashedUid,
    );
  }

  Future<void> _restore() async {
    final wasPremium = _premiumService.isPremium;
    await _premiumService.restorePurchases(
      uid: widget.uid,
      hashedUid: widget.hashedUid,
    );
    if (!mounted || wasPremium || _premiumService.errorMessage != null) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _premiumService.isPremium
              ? 'רכישת הפרימיום שוחזרה בהצלחה.'
              : 'בקשת השחזור הסתיימה. אם קיימת רכישה, החנות תעדכן אותה בקרוב.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('מצב פרימיום')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _premiumService,
          builder: (context, _) {
            final service = _premiumService;
            final busy =
                service.isLoading || service.isPending || service.isRestoring;
            final canBuy =
                !busy &&
                !service.isPremium &&
                service.storeAvailable &&
                service.productAvailable;

            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    service.isPremium
                        ? 'הפרימיום שלך פעיל'
                        : 'יותר חברים, בלי פרסומות',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  service.isPremium
                      ? 'כל תכונות הפרימיום פתוחות עבורך.'
                      : 'שדרוג קבוע בתשלום חד־פעמי.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                const _BenefitTile(
                  icon: Icons.group_add_outlined,
                  title: 'חברים ללא הגבלה',
                  subtitle: 'אפשר להוסיף יותר מ־7 חברים.',
                ),
                const _BenefitTile(
                  icon: Icons.block_outlined,
                  title: 'ללא פרסומות',
                  subtitle: 'חוויה נקייה ושקטה בכל האפליקציה.',
                ),
                const SizedBox(height: 20),
                if (service.isPremium)
                  const _StatusCard(
                    icon: Icons.verified,
                    color: Colors.green,
                    message: 'פרימיום פעיל במכשיר זה.',
                  )
                else if (service.isPending)
                  const _StatusCard(
                    icon: Icons.hourglass_top,
                    color: Colors.orange,
                    message:
                        'הרכישה ממתינה לאישור החנות. הפרימיום יופעל רק לאחר אישור.',
                    showProgress: true,
                  )
                else if (service.isRestoring)
                  const _StatusCard(
                    icon: Icons.restore,
                    color: Colors.indigo,
                    message: 'משחזר רכישות קודמות…',
                    showProgress: true,
                  )
                else if (service.isLoading &&
                    service.entitlementStatus == EntitlementStatus.unknown)
                  const _StatusCard(
                    icon: Icons.storefront_outlined,
                    color: Colors.indigo,
                    message: 'בודק את סטטוס הפרימיום…',
                    showProgress: true,
                  )
                else if (!service.storeAvailable)
                  const _StatusCard(
                    icon: Icons.store_mall_directory_outlined,
                    color: Colors.orange,
                    message: 'החנות אינה זמינה כרגע. בדוק את החיבור ונסה שוב.',
                  )
                else if (!service.productAvailable)
                  const _StatusCard(
                    icon: Icons.info_outline,
                    color: Colors.orange,
                    message: 'מוצר הפרימיום עדיין אינו זמין בחנות.',
                  ),
                if (service.errorMessage case final error?) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: const Text('לא ניתן להשלים את הפעולה'),
                      subtitle: Text(error),
                      trailing: IconButton(
                        tooltip: 'סגירת ההודעה',
                        onPressed: service.clearError,
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                if (!service.isPremium) ...[
                  Semantics(
                    button: true,
                    label: service.price == null
                        ? 'רכישת מצב פרימיום'
                        : 'רכישת מצב פרימיום במחיר ${service.price}',
                    child: FilledButton.icon(
                      onPressed: canBuy ? _buy : null,
                      icon: service.isPending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.workspace_premium_outlined),
                      label: Text(
                        service.price == null
                            ? 'רכישת פרימיום'
                            : 'רכישת פרימיום – ${service.price}',
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                OutlinedButton.icon(
                  onPressed: busy ? null : _restore,
                  icon: const Icon(Icons.restore),
                  label: const Text('שחזור רכישה'),
                ),
                if (!service.storeAvailable && !service.isLoading) ...[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: service.refreshStore,
                    icon: const Icon(Icons.refresh),
                    label: const Text('בדיקה מחדש'),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'הרכישה משויכת לחשבון החנות שלך וניתנת לשחזור במכשיר אחר.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _BenefitTile extends StatelessWidget {
  const _BenefitTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.icon,
    required this.color,
    required this.message,
    this.showProgress = false,
  });

  final IconData icon;
  final Color color;
  final String message;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: showProgress,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (showProgress)
                SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: color,
                  ),
                )
              else
                Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }
}
