import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../services/providers.dart';

/// Cash + bank accounts with their live computed balances.
class AccountsScreen extends ConsumerStatefulWidget {
  const AccountsScreen({super.key});

  @override
  ConsumerState<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends ConsumerState<AccountsScreen> {
  late Future<List<Json>> _future;

  static const _accentFor = {
    'cash': AppTheme.cIncome,
    'bank': AppTheme.cDebtor,
  };

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(repoProvider).accountsWithBalances();
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
                if (existing == null) {
                  await repo.insert('accounts', values);
                } else {
                  await repo.update(
                      'accounts', existing['id'].toString(), values);
                }
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
            style: FilledButton.styleFrom(backgroundColor: AppTheme.cExpense),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repoProvider).delete('accounts', a['id'].toString());
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accounts'),
        backgroundColor: AppTheme.cDebtor,
      ),
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
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _TotalCard(total: total),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _edit(initialType: 'bank'),
                        icon: const Icon(Icons.account_balance),
                        label: const Text('Add Bank'),
                        style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.cDebtor),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _edit(initialType: 'cash'),
                        icon: const Icon(Icons.payments),
                        label: const Text('Add Cash'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.cIncome),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (accounts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 60),
                    child: Center(child: Text('No accounts yet')),
                  ),
                ...accounts.map((a) {
                  final type = (a['type'] ?? 'cash').toString();
                  final color = _accentFor[type] ?? AppTheme.primary;
                  final bal = (a['balance'] as num?)?.toDouble() ?? 0;
                  return Card(
                    child: ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          type == 'bank'
                              ? Icons.account_balance
                              : Icons.payments,
                          color: color,
                          size: 20,
                        ),
                      ),
                      title: Text(a['name'].toString()),
                      subtitle: Text(type),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(money(bal),
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: bal < 0 ? AppTheme.cExpense : null)),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert),
                            onSelected: (v) =>
                                v == 'edit' ? _edit(existing: a) : _delete(a),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.total});
  final double total;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [AppTheme.primaryDark, AppTheme.accent],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Total balance',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 8),
          Text(money(total),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
