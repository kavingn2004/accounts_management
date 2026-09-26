import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/components.dart';
import '../../core/theme.dart';
import '../../data/history.dart';
import '../../services/providers.dart';
import 'alert_model.dart';
import 'alert_providers.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  Future<void> _addAlert(BuildContext context, WidgetRef ref) async {
    final titleC = TextEditingController();
    final msgC = TextEditingController();
    var sev = AlertSeverity.info;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('New alert'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleC,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: msgC,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Message'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AlertSeverity>(
                initialValue: sev,
                decoration: const InputDecoration(labelText: 'Severity'),
                items: AlertSeverity.values
                    .map((s) => DropdownMenuItem(
                          value: s,
                          child: Text(s.name),
                        ))
                    .toList(),
                onChanged: (v) => setSt(() => sev = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (titleC.text.trim().isEmpty) return;
                final repo = ref.read(repoProvider);
                await recordAction(
                  repo,
                  label: 'Added alert · ${titleC.text.trim()}',
                  table: 'alerts',
                  body: () => repo.insert('alerts', {
                    'title': titleC.text.trim(),
                    'message': msgC.text.trim(),
                    'severity': sev.name,
                    'type': 'custom',
                    'created_at': DateTime.now().toIso8601String(),
                  }),
                );
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) ref.invalidate(alertsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(visibleAlertsProvider);

    // Mark everything currently shown as seen (clears the badge).
    async.whenData((list) {
      final keys = list.map((a) => a.key).toSet();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final seen = ref.read(seenAlertsProvider);
        if (!keys.every(seen.contains)) {
          ref.read(seenAlertsProvider.notifier).state = {...seen, ...keys};
        }
      });
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      floatingActionButton: SizedBox(
        width: 52,
        height: 52,
        child: FloatingActionButton(
          onPressed: () => _addAlert(context, ref),
          child: const Icon(Icons.add, size: 22),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(alertsProvider),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.screenPad, 80, AppTheme.screenPad, 0),
            children: [EmptyState(title: "That didn't load", message: '$e')],
          ),
          data: (alerts) {
            if (alerts.isEmpty) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(
                    AppTheme.screenPad, 80, AppTheme.screenPad, 0),
                children: const [
                  EmptyState(
                    title: "You're all caught up",
                    message:
                        'Alerts clear themselves once the entry is recorded.',
                  ),
                ],
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.screenPad, 8, AppTheme.screenPad, 96),
              itemCount: alerts.length,
              itemBuilder: (_, i) {
                final a = alerts[i];
                return _AlertCard(
                  alert: a,
                  onDelete: () async {
                    if (a.isCustom) {
                      // Stored alert — really delete it.
                      final repo = ref.read(repoProvider);
                      await recordAction(
                        repo,
                        label: 'Deleted alert · ${a.title}',
                        table: 'alerts',
                        body: () => repo.delete('alerts', a.id!),
                      );
                      ref.invalidate(alertsProvider);
                    } else {
                      // Computed alert — dismiss for this session.
                      ref.read(dismissedAlertsProvider.notifier).update(
                            (s) => {...s, a.key},
                          );
                    }
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, this.onDelete});
  final AppAlert alert;
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sev = alert.severity.color(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: sev, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    alert.title,
                    style: context.text.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onDelete != null)
                  InkWell(
                    onTap: onDelete,
                    borderRadius: BorderRadius.circular(999),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.close,
                          size: 16, color: c.textSecondary),
                    ),
                  ),
              ],
            ),
            if (alert.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                alert.message,
                style:
                    context.text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              _formatTriggeredAt(alert.triggeredAt),
              style: context.text.labelSmall?.copyWith(
                color: c.textSecondary,
                fontFeatures: tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Today 14:32", "Yesterday 09:10", or "5 May 2026 · 14:32" for older alerts.
String _formatTriggeredAt(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final whenDay = DateTime(when.year, when.month, when.day);
  final time = DateFormat('HH:mm').format(when);
  final daysAgo = today.difference(whenDay).inDays;
  if (daysAgo == 0) return 'Today $time';
  if (daysAgo == 1) return 'Yesterday $time';
  return '${DateFormat('d MMM yyyy').format(when)} · $time';
}
