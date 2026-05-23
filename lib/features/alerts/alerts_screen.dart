import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
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
              style: FilledButton.styleFrom(backgroundColor: AppTheme.cAlerts),
              onPressed: () async {
                if (titleC.text.trim().isEmpty) return;
                await ref.read(repoProvider).insert('alerts', {
                  'title': titleC.text.trim(),
                  'message': msgC.text.trim(),
                  'severity': sev.name,
                  'type': 'custom',
                  'created_at': DateTime.now().toIso8601String(),
                });
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
      appBar: AppBar(
        title: const Text('Alerts'),
        backgroundColor: AppTheme.cAlerts,
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.cAlerts,
        onPressed: () => _addAlert(context, ref),
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(alertsProvider),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [
            const SizedBox(height: 80),
            Center(child: Text('Error: $e')),
          ]),
          data: (alerts) {
            if (alerts.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  Icon(Icons.check_circle_outline,
                      size: 56, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  Center(
                    child: Text("You're all caught up 🎉",
                        style: TextStyle(color: Colors.grey.shade600)),
                  ),
                ],
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: alerts.length,
              itemBuilder: (_, i) {
                final a = alerts[i];
                return _AlertCard(
                  alert: a,
                  onDelete: () async {
                    if (a.isCustom) {
                      // Stored alert — really delete it.
                      await ref.read(repoProvider).delete('alerts', a.id!);
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
    final c = alert.severity.color;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(alert.severity.icon, color: c, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(alert.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  if (alert.message.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(alert.message,
                        style: TextStyle(color: Colors.grey.shade700)),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.schedule,
                          size: 12, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(
                        _formatTriggeredAt(alert.triggeredAt),
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: Colors.grey,
                onPressed: onDelete,
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
