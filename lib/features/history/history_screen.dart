import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/components.dart';
import '../../core/theme.dart';
import '../../data/history.dart';
import '../../services/providers.dart';
import '../alerts/alert_providers.dart';
import '../registry.dart';
import 'history_backfill.dart';

/// What the user did in the last [HistoryLog.keepFor], newest first, each
/// with an Undo that reverses every row that action wrote.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  String? _busyId;
  bool _rebuilding = false;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  /// Fill in the past two weeks from the rows' creation times, including
  /// anything added on another device since the last look.
  Future<void> _rebuild() async {
    final repo = ref.read(repoProvider);
    if (repo is! HistoryRepository) return;
    setState(() => _rebuilding = true);
    try {
      await HistoryBackfill(repo, repo.log).run();
    } catch (_) {
      // What was already recorded still shows; the rest can wait for the
      // next visit.
    } finally {
      if (mounted) setState(() => _rebuilding = false);
    }
  }

  Future<void> _undo(HistoryRepository repo, HistoryEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Undo this change?'),
        content: Text(entry.ops.length > 1
            ? '${entry.label}\n\nEverything saved with it is reversed too, '
                'including account movements.'
            : entry.label),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busyId = entry.id);
    try {
      await repo.undo(entry.id);
      ref.read(dataRevisionProvider.notifier).state++;
      ref.invalidate(alertsProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Change undone')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not undo: $e')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repoProvider);
    final history = repo is HistoryRepository ? repo : null;
    final entries = ref.watch(historyLogProvider).entries();

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        bottom: _rebuilding
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: entries.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(AppTheme.screenPad),
              child: Align(
                alignment: Alignment.topCenter,
                child: EmptyState(
                  title: _rebuilding ? 'Loading the past two weeks…' : 'No history yet',
                  message: 'Everything you add, edit or delete shows up here '
                      'for ${HistoryLog.keepFor.inDays} days, and can be undone.',
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.screenPad, 8, AppTheme.screenPad, 32),
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final e = entries[i];
                return _HistoryRow(
                  entry: e,
                  showTopBorder: i > 0,
                  busy: _busyId == e.id,
                  canUndo: history?.canUndo(e, entries) ?? false,
                  onUndo: history == null ? null : () => _undo(history, e),
                );
              },
            ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.showTopBorder,
    required this.busy,
    required this.canUndo,
    this.onUndo,
  });

  final HistoryEntry entry;
  final bool showTopBorder;
  final bool busy;
  final bool canUndo;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (icon, tone) = _moduleLook(entry.table);
    final muted = entry.undone;

    Widget action;
    if (entry.undone) {
      action = Text('Undone',
          style: context.text.labelMedium?.copyWith(color: c.textSecondary));
    } else if (busy) {
      action = const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2));
    } else if (canUndo) {
      action = TextButton(onPressed: onUndo, child: const Text('Undo'));
    } else if (!entry.undoable) {
      action = Tooltip(
        message: 'Happened before History started, as part of a change that '
            'can\'t be reversed automatically',
        child: Text('View only',
            style: context.text.labelMedium?.copyWith(color: c.textSecondary)),
      );
    } else {
      action = const Tooltip(
        message: 'Undo the newer change first',
        child: TextButton(onPressed: null, child: Text('Undo')),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border:
            showTopBorder ? Border(top: BorderSide(color: c.border)) : null,
      ),
      child: Opacity(
        opacity: muted ? 0.55 : 1,
        child: Row(
          children: [
            IconChip(icon, tone),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.label,
                    style: context.text.titleMedium?.copyWith(
                      decoration: muted ? TextDecoration.lineThrough : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.rebuilt
                        ? '${_when(entry.at)} · from records'
                        : _when(entry.at),
                    style: context.text.bodySmall
                        ?.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            action,
          ],
        ),
      ),
    );
  }
}

/// Icon and colour of the module an entry belongs to.
(IconData, ModuleTone) _moduleLook(String table) {
  for (final m in Modules.all) {
    if (m.table == table) return (m.icon, m.tone);
  }
  return switch (table) {
    'accounts' => (Icons.account_balance_wallet_outlined, ModuleTone.debtor),
    'alerts' => (Icons.notifications_outlined, ModuleTone.alerts),
    _ => (Icons.history, ModuleTone.alerts),
  };
}

/// "Today 14:32", "Yesterday 09:10", or "5 May 2026 · 14:32".
String _when(DateTime at) {
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(at.year, at.month, at.day))
      .inDays;
  final time = DateFormat('HH:mm').format(at);
  if (days == 0) return 'Today $time';
  if (days == 1) return 'Yesterday $time';
  return '${DateFormat('d MMM yyyy').format(at)} · $time';
}
