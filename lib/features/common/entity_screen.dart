import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../models/field_spec.dart';
import '../../services/providers.dart';

/// Generic list + add screen driven entirely by an [EntityConfig].
/// Used by every module (income, expenses, savings, ...).
class EntityScreen extends ConsumerStatefulWidget {
  const EntityScreen({super.key, required this.config});

  final EntityConfig config;

  @override
  ConsumerState<EntityScreen> createState() => _EntityScreenState();
}

class _EntityScreenState extends ConsumerState<EntityScreen> {
  late Future<List<Json>> _future;
  List<String> _accountNames = [];

  EntityConfig get cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final rows = await ref.read(repoProvider).list('accounts');
    if (mounted) {
      setState(() => _accountNames = rows
          .map((r) => (r['name'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList());
    }
  }

  /// Record a signed cash movement against an account (for balance tracking).
  Future<void> _recordCashMove(String account, double signedAmount) async {
    await ref.read(repoProvider).insert('cash_moves', {
      'account': account,
      'amount': signedAmount,
      'date': isoDate(DateTime.now()),
      'note': cfg.title,
    });
  }

  /// Optional account dropdown used inside the add/pay dialogs.
  Widget _accountPicker(String label, String? value, ValueChanged<String?> on) {
    if (_accountNames.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem(value: null, child: Text('— None —')),
          ..._accountNames
              .map((a) => DropdownMenuItem(value: a, child: Text(a))),
        ],
        onChanged: on,
      ),
    );
  }

  void _reload() {
    _future = ref
        .read(repoProvider)
        .list(cfg.table, orderBy: cfg.orderBy, ascending: false);
  }

  Future<void> _refresh() async {
    setState(_reload);
    ref.read(dataRevisionProvider.notifier).state++;
    await _future;
  }

  Future<void> _openSheet({Json? existing}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EntrySheet(config: cfg, existing: existing),
    );
    if (saved == true) _refresh();
  }

  Future<bool> _confirmDelete(Json row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text('Delete "${cfg.titleOf(row)}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.cExpense),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _delete(Json row) async {
    await ref.read(repoProvider).delete(cfg.table, row['id'].toString());
    _refresh();
  }

  /// Increment a numeric column (e.g. savings saved_amount) by a typed amount.
  /// The money comes OUT of an optionally chosen account.
  Future<void> _addAmount(Json row) async {
    final field = cfg.incrementField!;
    final controller = TextEditingController();
    String? account;

    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(cfg.incrementLabel ?? 'Add amount'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                    labelText: 'Amount', prefixText: '+ '),
              ),
              _accountPicker('From account (optional)', account,
                  (v) => setSt(() => account = v)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cfg.color),
              onPressed: () =>
                  Navigator.pop(ctx, double.tryParse(controller.text.trim())),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (amount == null || amount == 0) return;
    final current = (row[field] as num?)?.toDouble() ?? 0;
    final values = <String, dynamic>{field: current + amount};
    final also = cfg.incrementAlsoField;
    if (also != null) {
      values[also] = ((row[also] as num?)?.toDouble() ?? 0) + amount;
    }
    await ref
        .read(repoProvider)
        .update(cfg.table, row['id'].toString(), values);
    if (account != null) await _recordCashMove(account!, -amount);
    _refresh();
  }

  /// Reduce a balance by a payment. If an interest-rate column is configured,
  /// one period (monthly) of interest is accrued before subtracting.
  Future<void> _payAmount(Json row) async {
    final field = cfg.decrementField!;
    final current = (row[field] as num?)?.toDouble() ?? 0;
    final rateField = cfg.interestRateField;
    double interest = 0;
    if (rateField != null) {
      final rate = (row[rateField] as num?)?.toDouble() ?? 0;
      interest = current * (rate / 100 / 12);
    }

    final controller = TextEditingController();
    String? account;
    final accountLabel =
        cfg.paymentInflow ? 'To account (optional)' : 'From account (optional)';

    final payment = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(cfg.decrementLabel ?? 'Add payment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Balance: ${money(current)}'),
              if (rateField != null) ...[
                const SizedBox(height: 4),
                Text('Interest this period: +${money(interest)}',
                    style:
                        TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                    labelText: 'Payment amount', prefixText: '- '),
              ),
              _accountPicker(
                  accountLabel, account, (v) => setSt(() => account = v)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cfg.color),
              onPressed: () =>
                  Navigator.pop(ctx, double.tryParse(controller.text.trim())),
              child: const Text('Pay'),
            ),
          ],
        ),
      ),
    );
    if (payment == null || payment == 0) return;
    var next = current + interest - payment;
    if (next < 0) next = 0;
    await ref.read(repoProvider).update(cfg.table, row['id'].toString(),
        {field: double.parse(next.toStringAsFixed(2))});
    if (account != null) {
      // Debtor repayment is money IN; creditor/loan/bill is money OUT.
      await _recordCashMove(account!, cfg.paymentInflow ? payment : -payment);
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(cfg.title),
        backgroundColor: cfg.color,
      ),
      floatingActionButton: cfg.readOnly
          ? null
          : FloatingActionButton(
              onPressed: _openSheet,
              backgroundColor: cfg.color,
              child: const Icon(Icons.add),
            ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Json>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _ErrorView(message: '${snap.error}');
            }
            final rows = snap.data ?? [];
            if (rows.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  Center(child: Text('No ${cfg.title.toLowerCase()} yet')),
                ],
              );
            }
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = rows[i];
                return Dismissible(
                  key: ValueKey(r['id']),
                  direction: cfg.readOnly
                      ? DismissDirection.none
                      : DismissDirection.endToStart,
                  background: Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete),
                  ),
                  confirmDismiss: (_) => _confirmDelete(r),
                  onDismissed: (_) => _delete(r),
                  child: ListTile(
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: cfg.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(cfg.icon, color: cfg.color, size: 20),
                    ),
                    title: Text(cfg.titleOf(r)),
                    subtitle: cfg.subtitleOf != null
                        ? Text(cfg.subtitleOf!(r))
                        : null,
                    trailing: cfg.readOnly
                        ? (cfg.trailingOf != null
                            ? Text(cfg.trailingOf!(r),
                                style:
                                    const TextStyle(fontWeight: FontWeight.bold))
                            : null)
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (cfg.trailingOf != null)
                                Text(cfg.trailingOf!(r),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                onSelected: (v) async {
                                  if (v == 'add_amount') {
                                    _addAmount(r);
                                  } else if (v == 'pay') {
                                    _payAmount(r);
                                  } else if (v == 'edit') {
                                    _openSheet(existing: r);
                                  } else if (v == 'delete') {
                                    if (await _confirmDelete(r)) _delete(r);
                                  }
                                },
                                itemBuilder: (_) => [
                                  if (cfg.incrementField != null)
                                    PopupMenuItem(
                                      value: 'add_amount',
                                      child: ListTile(
                                        leading: Icon(Icons.add_circle_outline,
                                            color: cfg.color),
                                        title: Text(
                                            cfg.incrementLabel ?? 'Add amount'),
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  if (cfg.decrementField != null)
                                    PopupMenuItem(
                                      value: 'pay',
                                      child: ListTile(
                                        leading: Icon(Icons.payments_outlined,
                                            color: cfg.color),
                                        title: Text(
                                            cfg.decrementLabel ?? 'Add payment'),
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: ListTile(
                                      leading: Icon(Icons.edit_outlined),
                                      title: Text('Edit'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: ListTile(
                                      leading: Icon(Icons.delete_outline,
                                          color: AppTheme.cExpense),
                                      title: Text('Delete'),
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                    onTap: cfg.readOnly ? null : () => _openSheet(existing: r),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        const Icon(Icons.error_outline, size: 48),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, textAlign: TextAlign.center),
        ),
      ],
    );
  }
}

/// Bottom-sheet form built dynamically from the config's field specs.
/// When [existing] is supplied it edits that row; otherwise it creates one.
class _EntrySheet extends ConsumerStatefulWidget {
  const _EntrySheet({required this.config, this.existing});
  final EntityConfig config;
  final Json? existing;

  @override
  ConsumerState<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends ConsumerState<_EntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, DateTime> _dates = {};
  final Map<String, String> _selects = {};
  final Map<String, List<String>> _dynamicOptions = {};
  bool _busy = false;
  String? _error;

  EntityConfig get cfg => widget.config;
  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    for (final f in cfg.fields) {
      final current = e?[f.key];
      switch (f.type) {
        case FieldType.text:
        case FieldType.number:
          _controllers[f.key] =
              TextEditingController(text: current?.toString() ?? '');
          break;
        case FieldType.select:
          final cur = current?.toString();
          if (cur != null && cur.isNotEmpty) {
            _selects[f.key] = cur;
          } else if (f.optionsTable == null &&
              (f.options?.isNotEmpty ?? false)) {
            _selects[f.key] = f.options!.first; // static default
          } else {
            _selects[f.key] = ''; // none / not chosen yet
          }
          break;
        case FieldType.date:
          final parsed = current == null
              ? null
              : DateTime.tryParse(current.toString());
          if (parsed != null) _dates[f.key] = parsed;
          break;
      }
    }
    _loadDynamicOptions();
  }

  Future<void> _loadDynamicOptions() async {
    final repo = ref.read(repoProvider);
    for (final f in cfg.fields) {
      final t = f.optionsTable;
      if (t != null && !_dynamicOptions.containsKey(t)) {
        final rows = await repo.list(t);
        _dynamicOptions[t] = rows
            .map((r) => (r['name'] ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toList();
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final values = <String, dynamic>{};
      for (final f in cfg.fields) {
        switch (f.type) {
          case FieldType.text:
            final t = _controllers[f.key]!.text.trim();
            if (t.isNotEmpty) values[f.key] = t;
            break;
          case FieldType.number:
            final t = _controllers[f.key]!.text.trim();
            if (t.isNotEmpty) values[f.key] = num.tryParse(t);
            break;
          case FieldType.date:
            if (_dates[f.key] != null) {
              values[f.key] = isoDate(_dates[f.key]!);
            }
            break;
          case FieldType.select:
            final v = _selects[f.key] ?? '';
            values[f.key] = v.isEmpty ? null : v;
            break;
        }
      }
      final repo = ref.read(repoProvider);
      if (_isEdit) {
        await repo.update(cfg.table, widget.existing!['id'].toString(), values);
      } else {
        await repo.insert(cfg.table, values);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset + 16),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${_isEdit ? 'Edit' : 'Add'} ${cfg.title}',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ...cfg.fields.map(_buildField),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_isEdit ? 'Update' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(FieldSpec f) {
    Widget child;
    switch (f.type) {
      case FieldType.text:
        child = TextFormField(
          controller: _controllers[f.key],
          decoration: InputDecoration(labelText: f.label),
          validator: _req(f),
        );
        break;
      case FieldType.number:
        child = TextFormField(
          controller: _controllers[f.key],
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: InputDecoration(labelText: f.label),
          validator: _req(f),
        );
        break;
      case FieldType.select:
        final isDynamic = f.optionsTable != null;
        final opts = isDynamic
            ? (_dynamicOptions[f.optionsTable] ?? const <String>[])
            : (f.options ?? const <String>[]);
        final current = _selects[f.key] ?? '';
        String? value;
        if (current.isNotEmpty && opts.contains(current)) {
          value = current;
        } else if (current.isEmpty && !f.required) {
          value = '';
        }
        child = DropdownButtonFormField<String>(
          initialValue: value,
          decoration: InputDecoration(labelText: f.label),
          items: [
            if (!f.required)
              const DropdownMenuItem(value: '', child: Text('— None —')),
            ...opts.map((o) => DropdownMenuItem(value: o, child: Text(o))),
          ],
          onChanged: (v) => setState(() => _selects[f.key] = v ?? ''),
          validator: f.required
              ? (v) => (v == null || v.isEmpty) ? 'Required' : null
              : null,
        );
        break;
      case FieldType.date:
        final d = _dates[f.key];
        child = InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: d ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (picked != null) setState(() => _dates[f.key] = picked);
          },
          child: InputDecorator(
            decoration: InputDecoration(labelText: f.label),
            child: Text(d == null ? 'Select date' : isoDate(d)),
          ),
        );
        break;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: child,
    );
  }

  String? Function(String?)? _req(FieldSpec f) {
    if (!f.required) return null;
    return (v) => (v == null || v.trim().isEmpty) ? 'Required' : null;
  }
}
