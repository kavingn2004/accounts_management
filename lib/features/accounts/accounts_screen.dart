import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/charts.dart';
import '../../core/components.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../data/history.dart';
import '../../services/providers.dart';
import '../common/module_metrics.dart';
import 'account_metrics.dart';

/// Cash + bank accounts with their live computed balances.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  late Future<List<Json>> _future;
  late Future<Series?> _chart;

  static const _toneFor = {
    'cash': ModuleTone.bills,
    'bank': ModuleTone.savings,
  };

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final repo = ref.read(repoProvider);
    _future = repo.accountsWithBalances();
    _chart = _loadChart(repo);
  }

  /// Balance over time, walked from the dated movements the app already keeps.
  /// Accounts is the one page that needs no ledger — every movement against an
  /// account carries a date.
  Future<Series?> _loadChart(FinanceRepository repo) async {
    final lists = await Future.wait([
      repo.list('accounts'),
      repo.list('income'),
      repo.list('expenses'),
      repo.list('transfers'),
      repo.list('cash_moves'),
    ]);
    return accountBalanceSeries(
      accounts: lists[0],
      income: lists[1],
      expenses: lists[2],
      transfers: lists[3],
      cashMoves: lists[4],
      now: DateTime.now(),
    );
  }
  Future<void> _refresh() async {
    setState(_reload);
    ref.read(dataRevisionProvider.notifier).state++;
    await _future;
  }

  Future<void> _edit({Json? existing, String initialType = 'cash'}) async {
    final nameC = TextEditingController(text: existing?['name']?.toString());
    final openC = TextEditingController(
        text: existing?['opening_balance']?.toString() ?? '');
    var type = (existing?['type'] ?? initialType).toString();

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(existing == null ? 'New account' : 'Edit account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameC,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'bank', child: Text('Bank')),
                ],
                onChanged: (v) => setSt(() => type = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: openC,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(labelText: 'Opening balance'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                if (nameC.text.trim().isEmpty) return;
                final values = {
                  'name': nameC.text.trim(),
                  'type': type,
                  'opening_balance':
                      double.tryParse(openC.text.trim()) ?? 0,
                };
                final repo = ref.read(repoProvider);
                await recordAction(
                  repo,
                  label: '${existing == null ? 'Added' : 'Edited'} account · '
                      '${values['name']}',
                  table: 'accounts',
                  body: () => existing == null
                      ? repo.insert('accounts', values)
                      : repo.update(
                          'accounts', existing['id'].toString(), values),
                );
                ref.read(dataRevisionProvider.notifier).state++;
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (mounted) _refresh(); // always reload after the dialog closes
  }

  Future<void> _delete(Json a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: Text(
            'Delete "${a['name']}"? Transactions tagged to it stay but won\'t count toward any balance.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ctx.colors.negative,
              foregroundColor: ctx.colors.surface,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(repoProvider);
    await recordAction(
      repo,
      label: 'Deleted account · ${a['name']}',
      table: 'accounts',
      body: () => repo.delete('accounts', a['id'].toString()),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Json>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final accounts = snap.data ?? [];
            final total = accounts.fold<double>(
                0, (a, r) => a + ((r['balance'] as num?)?.toDouble() ?? 0));
            final c = context.colors;
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.screenPad, 8, AppTheme.screenPad, 24),
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total across ${accounts.length} '
                      '${accounts.length == 1 ? 'account' : 'accounts'}',
                      style: context.text.labelMedium
                          ?.copyWith(color: c.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    MoneyText(money(total),
                        style: context.text.displayLarge),
                  ],
                ),
                const SizedBox(height: 16),
                if (accounts.isNotEmpty)
                  AppCard(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: FutureBuilder<Series?>(
                      future: _chart,
                      builder: (context, chartSnap) {
                        final series = chartSnap.data;
                        if (series == null) {
                          return const ChartEmptyState(
                            message: 'Movements you record will appear here.',
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SectionLabel('Balance over time'),
                            SeriesChart(series: series),
                          ],
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 20),
                if (accounts.isEmpty)
                  const EmptyState(
                    title: 'No accounts yet',
                    message:
                        'Add a bank or cash account to start tracking balances.',
                  ),
                ...accounts.map((a) {
                  final type = (a['type'] ?? 'cash').toString();
                  final tone = _toneFor[type] ?? ModuleTone.savings;
                  final bal = (a['balance'] as num?)?.toDouble() ?? 0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: AppCard(
                      padding: const EdgeInsets.all(16),
                      onTap: () => _edit(existing: a),
                      child: Row(
                        children: [
                          IconChip(
                            type == 'bank'
                                ? Icons.account_balance
                                : Icons.payments_outlined,
                            tone,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(a['name'].toString(),
                                    style: context.text.titleMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 2),
                                Text(type,
                                    style: context.text.bodySmall
                                        ?.copyWith(color: c.textSecondary)),
                              ],
                            ),
                          ),
                          MoneyText(money(bal),
                              color: bal < 0 ? c.negative : null),
                          PopupMenuButton<String>(
                            icon: Icon(Icons.more_vert,
                                size: 18, color: c.textSecondary),
                            padding: EdgeInsets.zero,
                            color: c.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppTheme.rControl),
                              side: BorderSide(color: c.border),
                            ),
                            onSelected: (v) =>
                                v == 'edit' ? _edit(existing: a) : _delete(a),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                  value: 'edit',
                                  height: 44,
                                  child: Text('Edit',
                                      style: context.text.bodyMedium)),
                              PopupMenuItem(
                                  value: 'delete',
                                  height: 44,
                                  child: Text('Delete',
                                      style: context.text.bodyMedium
                                          ?.copyWith(color: c.negative))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _edit(initialType: 'bank'),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add bank'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _edit(initialType: 'cash'),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add cash'),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
