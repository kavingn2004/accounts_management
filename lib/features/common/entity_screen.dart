import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/components.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../data/module_event.dart';
import '../../models/field_spec.dart';
import '../../services/providers.dart';
import 'export_service.dart';

/// The calendar day a row belongs to, or null when nothing parseable is there.
///
/// Timestamps are normalised to the local day before comparing: Postgres hands
/// back `created_at` in UTC while the filter boundaries are local dates, so
/// comparing them as raw instants would include or drop rows near midnight
/// depending on the machine's timezone.
DateTime? _rowDay(Object? value) {
  final parsed = DateTime.tryParse((value ?? '').toString());
  if (parsed == null) return null;
  final local = parsed.isUtc ? parsed.toLocal() : parsed;
  return DateTime(local.year, local.month, local.day);
}

/// Rows falling inside [range] (inclusive on both ends). A null range means
/// "All" and returns every row untouched.
///
/// Rows are placed by their `date` field, falling back to `created_at` when
/// `date` is absent or unparseable. When neither can be read the row is KEPT:
/// a record that exists in the database must never be silently invisible in
/// the UI, and the previous behaviour dropped such rows from every range
/// except "All", which made stored data look like it had never saved.
@visibleForTesting
List<Json> filterRowsByDate(List<Json> rows, DateTimeRange? range) {
  if (range == null) return rows;
  final start = DateTime(range.start.year, range.start.month, range.start.day);
  final end = DateTime(range.end.year, range.end.month, range.end.day);
  return rows.where((r) {
    final day = _rowDay(r['date']) ?? _rowDay(r['created_at']);
    if (day == null) return true;
    return !day.isBefore(start) && !day.isAfter(end);
  }).toList();
}

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

  // Date-range filter state (only used when cfg.dateFiltered is true).
  _DateRange _dateRange = _DateRange.month;
  DateTimeRange? _customRange;

  EntityConfig get cfg => widget.config;

  /// Returns the inclusive date range the filter is currently set to, or
  /// null when "All" is active (or when no filter has been applied).
  DateTimeRange? _activeRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_dateRange) {
      case _DateRange.today:
        return DateTimeRange(start: today, end: today);
      case _DateRange.week:
        return DateTimeRange(
          start: today.subtract(const Duration(days: 6)),
          end: today,
        );
      case _DateRange.month:
        return DateTimeRange(
          start: DateTime(now.year, now.month, 1),
          end: DateTime(now.year, now.month + 1, 0),
        );
      case _DateRange.year:
        return DateTimeRange(
          start: DateTime(now.year, 1, 1),
          end: DateTime(now.year, 12, 31),
        );
      case _DateRange.all:
        return null;
      case _DateRange.custom:
        return _customRange;
    }
  }

  /// Apply the date filter to a list of rows. Returns input unchanged when
  /// the config isn't date-filtered or "All" is selected.
  List<Json> _applyFilter(List<Json> rows) =>
      cfg.dateFiltered ? filterRowsByDate(rows, _activeRange()) : rows;

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final initial = _customRange ??
        DateTimeRange(
          start: now.subtract(const Duration(days: 7)),
          end: now,
        );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: initial,
      saveText: 'Apply',
    );
    if (picked != null) {
      setState(() {
        _customRange = picked;
        _dateRange = _DateRange.custom;
      });
    }
  }

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

  /// Append a ledger entry for a value change on [row].
  ///
  /// Best-effort — the update it describes has already been committed, so a
  /// failure here must not surface or roll anything back (see [logModuleEvent]).
  Future<void> _logEvent({
    required Json row,
    required String field,
    required EventKind kind,
    required double amount,
    required double balanceAfter,
    String? account,
  }) =>
      logModuleEvent(
        ref.read(repoProvider),
        ModuleEvent(
          parentId: row['id'].toString(),
          parentType: cfg.table,
          field: field,
          kind: kind,
          amount: amount,
          balanceAfter: balanceAfter,
          date: DateTime.now(),
          account: account,
          note: cfg.title,
        ),
      );

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
    if (saved != true) return;
    if (existing == null) await _logOpeningEvent();
    _refresh();
  }

  /// Ledger entry for a newly created row.
  ///
  /// Written here rather than inside the sheet because the id is generated by
  /// the repository on insert, so it is only knowable after the table is
  /// re-read. Without it a goal created at ₹50,000 and never topped up would
  /// have no events at all, and its curve would start at zero.
  Future<void> _logOpeningEvent() async {
    final field = cfg.incrementField ?? cfg.decrementField;
    if (field == null) return;
    final rows = await ref.read(repoProvider).list(cfg.table);
    if (rows.isEmpty) return;
    // Both repositories return newest-first, so this is the row just written.
    final row = rows.first;
    final opening = (row[field] as num?)?.toDouble() ?? 0;
    await _logEvent(
      row: row,
      field: field,
      kind: EventKind.open,
      amount: opening,
      balanceAfter: opening,
    );
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
    final cum = cfg.cumulativeIncrementField;
    if (cum != null) {
      values[cum] = ((row[cum] as num?)?.toDouble() ?? 0) + amount;
    }
    await ref
        .read(repoProvider)
        .update(cfg.table, row['id'].toString(), values);
    await _logEvent(
      row: row,
      field: field,
      kind: EventKind.increment,
      amount: amount,
      balanceAfter: current + amount,
      account: account,
    );
    // A second entry for the mirrored column — this is what lets the
    // Investment chart draw invested and current value as two lines from a
    // single contribution.
    if (also != null) {
      await _logEvent(
        row: row,
        field: also,
        kind: EventKind.increment,
        amount: amount,
        balanceAfter: values[also] as double,
      );
    }
    if (account != null) await _recordCashMove(account!, -amount);
    _refresh();
  }

  /// Overwrite a numeric column with a typed value (e.g. update an
  /// investment's current market value). Replaces rather than adds; no
  /// account movement is recorded.
  Future<void> _setValue(Json row) async {
    final field = cfg.setField!;
    final current = (row[field] as num?)?.toDouble() ?? 0;
    // Prefill with the current value, dropping a redundant trailing ".0".
    final prefill = current == 0
        ? ''
        : (current == current.roundToDouble()
            ? current.toInt().toString()
            : current.toString());
    final controller = TextEditingController(text: prefill);

    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(cfg.setLabel ?? 'Update value'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current: ${money(current)}',
                style: context.text.labelMedium
                      ?.copyWith(color: context.colors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(labelText: 'New value'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, double.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null) return;
    await ref.read(repoProvider).update(
        cfg.table, row['id'].toString(), {field: value});
    // A revaluation replaces rather than adjusts, so `amount` carries the new
    // figure — there is no meaningful delta to record.
    await _logEvent(
      row: row,
      field: field,
      kind: EventKind.set,
      amount: value,
      balanceAfter: value,
    );
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

    // Optional next-due-date picker (e.g. creditors/debtors). Pre-fill from the
    // row's current due date so the user can roll it forward with the payment.
    final dueField = cfg.dueDateField;
    DateTime? due = dueField == null
        ? null
        : DateTime.tryParse((row[dueField] ?? '').toString());

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
                        context.text.labelMedium?.copyWith(
                            color: context.colors.textSecondary)),
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
              if (dueField != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: due ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setSt(() => due = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Next due date'),
                      child: Text(due == null ? 'Select date' : isoDate(due!)),
                    ),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, double.tryParse(controller.text.trim())),
              child: const Text('Pay'),
            ),
          ],
        ),
      ),
    );
    if (payment == null || payment == 0) return;
    // Can't pay more than is owed (balance + this period's interest).
    final payable = current + interest;
    final pay = payment > payable ? payable : payment;
    var next = payable - pay;
    if (next < 0) next = 0;
    final updates = <String, dynamic>{
      field: double.parse(next.toStringAsFixed(2)),
    };
    // Move the settlement status as the balance is paid down part by part.
    if (cfg.statusField != null) {
      final original =
          (row[cfg.originalAmountField] as num?)?.toDouble() ?? current;
      final settled = next <= 0;
      updates[cfg.statusField!] =
          settled ? 'settled' : (next < original ? 'partial' : 'open');
      // Note where the closing payment landed (received in / paid from).
      if (settled && cfg.settledAccountField != null && account != null) {
        updates[cfg.settledAccountField!] = account;
      }
    }
    if (dueField != null && due != null) updates[dueField] = isoDate(due!);
    await ref.read(repoProvider).update(cfg.table, row['id'].toString(), updates);
    // `next` is the balance actually written — after interest accrual, so the
    // curve agrees with the figure on the row rather than with the payment.
    await _logEvent(
      row: row,
      field: field,
      kind: EventKind.decrement,
      amount: pay,
      balanceAfter: updates[field] as double,
      account: account,
    );
    if (account != null) {
      // Debtor repayment is money IN; creditor/loan/bill is money OUT.
      await _recordCashMove(account!, cfg.paymentInflow ? pay : -pay);
    }
    // Log this installment to the per-person payment ledger. Best-effort: a
    // missing ledger table (e.g. migration not yet run) must not fail the
    // payment itself, which is already recorded above.
    if (cfg.paymentsTable != null) {
      try {
        await ref.read(repoProvider).insert(cfg.paymentsTable!, {
          'parent_id': row['id'].toString(),
          'parent_type': cfg.table,
          'amount': pay,
          'account': account,
          'date': isoDate(DateTime.now()),
        });
      } catch (_) {
        // Ledger is non-critical; ignore and keep the payment.
      }
    }
    _refresh();
  }

  /// Close a debt. If an account is chosen, the remaining balance is treated as
  /// actually received (debtor) / paid (creditor) through it: the account
  /// balance moves and the row is zeroed. With no account it's a pure write-off
  /// — marked settled but the remaining amount is kept for history.
  Future<void> _markSettled(Json row) async {
    final field = cfg.decrementField;
    final remaining = (row[field] as num?)?.toDouble() ?? 0;
    String? account;
    final label = cfg.paymentInflow
        ? 'Received in account (optional)'
        : 'Paid from account (optional)';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Mark as settled'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Close "${cfg.titleOf(row)}"?'),
              if (remaining > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'Pick an account to record the remaining ${money(remaining)} '
                  'as ${cfg.paymentInflow ? 'received' : 'paid'}. Leave blank '
                  'to just close it without moving money.',
                  style: context.text.labelMedium
                      ?.copyWith(color: context.colors.textSecondary),
                ),
              ],
              _accountPicker(label, account, (v) => setSt(() => account = v)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Settle'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final repo = ref.read(repoProvider);
    final updates = <String, dynamic>{cfg.statusField!: 'settled'};
    if (account != null) {
      // Money actually changed hands — zero the balance and note the account.
      if (field != null) updates[field] = 0;
      if (cfg.settledAccountField != null) {
        updates[cfg.settledAccountField!] = account;
      }
    }
    await repo.update(cfg.table, row['id'].toString(), updates);

    // Only a settlement through an account moves a balance. A pure write-off
    // leaves the amount intact for history, so there is no value change to
    // record — and inventing a drop here would put a cliff on the outstanding
    // curve that never happened (see the same rule in trends.dart).
    if (account != null && field != null) {
      await _logEvent(
        row: row,
        field: field,
        kind: EventKind.set,
        amount: 0,
        balanceAfter: 0,
        account: account,
      );
    }

    if (account != null && remaining != 0) {
      // Debtor = money IN to the account; creditor = money OUT.
      await _recordCashMove(account!, cfg.paymentInflow ? remaining : -remaining);
      if (cfg.paymentsTable != null) {
        try {
          await repo.insert(cfg.paymentsTable!, {
            'parent_id': row['id'].toString(),
            'parent_type': cfg.table,
            'amount': remaining,
            'account': account,
            'date': isoDate(DateTime.now()),
          });
        } catch (_) {
          // Ledger is non-critical.
        }
      }
    }
    _refresh();
  }

  /// Reopen a settled debt, recomputing status from the remaining balance.
  Future<void> _reopen(Json row) async {
    final remaining = (row[cfg.decrementField] as num?)?.toDouble() ?? 0;
    final original =
        (row[cfg.originalAmountField] as num?)?.toDouble() ?? remaining;
    final status = remaining > 0 && remaining < original ? 'partial' : 'open';
    final updates = <String, dynamic>{cfg.statusField!: status};
    // Clear the stale settling account so it can't resurface if re-settled.
    if (cfg.settledAccountField != null) {
      updates[cfg.settledAccountField!] = null;
    }
    await ref.read(repoProvider).update(cfg.table, row['id'].toString(), updates);
    _refresh();
  }

  /// Bottom sheet listing every installment paid against this row.
  Future<void> _showPayments(Json row) async {
    List<Json> mine;
    try {
      final all = await ref.read(repoProvider).list(cfg.paymentsTable!);
      final id = row['id'].toString();
      mine = all.where((p) => p['parent_id']?.toString() == id).toList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Payment history unavailable. Run the debt_payments migration '
              'in Supabase. ($e)'),
        ),
      );
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Payments — ${cfg.titleOf(row)}',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (mine.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('No payments yet')),
                )
              else
                ...mine.map((p) {
                  final acct = (p['account'] ?? '').toString();
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.payments_outlined,
                        color: cfg.tone.of(context)),
                    title: Text(money(p['amount'] as num?)),
                    subtitle: Text([
                      prettyDate(p['date']?.toString()),
                      if (acct.isNotEmpty) acct,
                    ].where((s) => s.isNotEmpty).join(' · ')),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export(_ExportFormat fmt) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final all = await ref
          .read(repoProvider)
          .list(cfg.table, orderBy: cfg.orderBy, ascending: false);
      final rows = _applyFilter(all);
      if (rows.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text('No ${cfg.title.toLowerCase()} to export')),
        );
        return;
      }
      if (fmt == _ExportFormat.csv) {
        await ExportService.exportCsv(cfg, rows);
      } else {
        await ExportService.exportPdf(cfg, rows);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(cfg.title),
        actions: [
          if (cfg.exportable)
            PopupMenuButton<_ExportFormat>(
              tooltip: 'Export',
              icon: const Icon(Icons.file_download_outlined),
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _ExportFormat.csv,
                  child: ListTile(
                    leading: Icon(Icons.table_chart_outlined),
                    title: Text('Export CSV'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _ExportFormat.pdf,
                  child: ListTile(
                    leading: Icon(Icons.picture_as_pdf_outlined),
                    title: Text('Export PDF'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
        ],
      ),
      floatingActionButton: cfg.readOnly
          ? null
          : SizedBox(
              width: 52,
              height: 52,
              child: FloatingActionButton(
                onPressed: _openSheet,
                child: const Icon(Icons.add, size: 22),
              ),
            ),
      body: Column(
        children: [
          if (cfg.dateFiltered) _buildFilterBar(),
          Expanded(
            child: RefreshIndicator(
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
                  final allRows = snap.data ?? [];
                  final rows = _applyFilter(allRows);
                  if (rows.isEmpty) {
                    final hasAny = allRows.isNotEmpty;
                    final inRange = hasAny && cfg.dateFiltered;
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(
                          AppTheme.screenPad, 80, AppTheme.screenPad, 0),
                      children: [
                        EmptyState(
                          title: inRange
                              ? 'Nothing in this range'
                              : 'No ${cfg.title.toLowerCase()} yet',
                          message: inRange
                              ? 'Widen the filter, or add an entry with the + button.'
                              : 'Tap + to record your first entry.',
                        ),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      if (cfg.dateFiltered) _summaryBanner(rows),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.only(
                            left: AppTheme.screenPad,
                            right: AppTheme.screenPad,
                            bottom: 96,
                          ),
                          itemCount: rows.length,
                          itemBuilder: (context, i) => _buildRow(
                            context,
                            rows[i],
                            isLast: i == rows.length - 1,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Every editable row gets the overflow button. Design 1e draws the Expenses
  /// row ending at the amount, but that render had no destructive actions to
  /// place — leaving edit/delete reachable only by swipe is a real regression
  /// on web, where dragging a row is awkward. The button is a muted 18px glyph,
  /// so the row still reads as the design intends.
  bool get _hasRowActions => true;

  Widget _buildRow(BuildContext context, Json r, {bool isLast = false}) {
    final c = context.colors;
    final row = Container(
      height: AppTheme.rowHeight,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: c.border),
          bottom: isLast ? BorderSide(color: c.border) : BorderSide.none,
        ),
      ),
      child: Row(
        children: [
          IconChip(cfg.icon, cfg.tone),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  cfg.titleOf(r),
                  style: context.text.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (cfg.subtitleOf != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    cfg.subtitleOf!(r),
                    style:
                        context.text.bodyMedium?.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (cfg.trailingOf != null) ...[
            const SizedBox(width: 8),
            MoneyText(cfg.trailingOf!(r)),
          ],
          if (!cfg.readOnly && _hasRowActions) _rowMenu(r),
        ],
      ),
    );

    return Dismissible(
      key: ValueKey(r['id']),
      direction: cfg.readOnly
          ? DismissDirection.none
          : DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: c.negative.withValues(alpha: 0.12),
        child: Icon(Icons.delete_outline, color: c.negative, size: 20),
      ),
      confirmDismiss: (_) => _confirmDelete(r),
      onDismissed: (_) => _delete(r),
      child: InkWell(
        onTap: cfg.readOnly ? null : () => _openSheet(existing: r),
        child: row,
      ),
    );
  }

  Widget _rowMenu(Json r) {
    final c = context.colors;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: c.textSecondary),
      padding: EdgeInsets.zero,
      splashRadius: 18,
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.rControl),
        side: BorderSide(color: c.border),
      ),
      onSelected: (v) async {
        if (v == 'add_amount') {
          _addAmount(r);
        } else if (v == 'set_value') {
          _setValue(r);
        } else if (v == 'pay') {
          _payAmount(r);
        } else if (v == 'payments') {
          _showPayments(r);
        } else if (v == 'settle') {
          _markSettled(r);
        } else if (v == 'reopen') {
          _reopen(r);
        } else if (v == 'edit') {
          _openSheet(existing: r);
        } else if (v == 'delete') {
          if (await _confirmDelete(r)) _delete(r);
        }
      },
      itemBuilder: (_) => [
        if (cfg.incrementField != null)
          _menuItem('add_amount', Icons.add_circle_outline,
              cfg.incrementLabel ?? 'Add amount', cfg.tone.of(context)),
        if (cfg.setField != null)
          _menuItem('set_value', Icons.edit_note,
              cfg.setLabel ?? 'Update value', cfg.tone.of(context)),
        if (cfg.decrementField != null && (r['status'] ?? '') != 'settled')
          _menuItem('pay', Icons.payments_outlined,
              cfg.decrementLabel ?? 'Add payment', cfg.tone.of(context)),
        if (cfg.paymentsTable != null)
          _menuItem('payments', Icons.history, 'Payments',
              cfg.tone.of(context)),
        if (cfg.statusField != null && (r['status'] ?? '') != 'settled')
          _menuItem('settle', Icons.check_circle_outline, 'Mark as settled',
              c.positive),
        if (cfg.statusField != null && (r['status'] ?? '') == 'settled')
          _menuItem('reopen', Icons.lock_open_outlined, 'Reopen',
              c.textSecondary),
        _menuItem('edit', Icons.edit_outlined, 'Edit', c.textSecondary),
        _menuItem('delete', Icons.delete_outline, 'Delete', c.negative),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
      String value, IconData icon, String label, Color color) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          // Flexible, not bare Text: long labels ("Update current value")
          // otherwise overflow the popup's constrained width.
          Flexible(
            child: Text(
              label,
              style: context.text.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
            AppTheme.screenPad, 0, AppTheme.screenPad, 12),
        itemCount: _DateRange.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final r = _DateRange.values[i];
          return AppFilterChip(
            label: _chipLabel(r),
            selected: _dateRange == r,
            onTap: () {
              if (r == _DateRange.custom) {
                _pickCustomRange();
              } else {
                setState(() => _dateRange = r);
              }
            },
          );
        },
      ),
    );
  }

  String _chipLabel(_DateRange r) {
    if (r == _DateRange.custom && _customRange != null) {
      final f = DateFormat('d MMM');
      return '${f.format(_customRange!.start)} – ${f.format(_customRange!.end)}';
    }
    return r.label;
  }

  Widget _summaryBanner(List<Json> rows) {
    final total = rows.fold<double>(
      0,
      (a, r) => a + ((r['amount'] as num?)?.toDouble() ?? 0),
    );
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 12),
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _summaryLabel(),
                    style: context.text.labelMedium
                        ?.copyWith(color: c.textSecondary),
                  ),
                  const SizedBox(height: 2),
                  MoneyText(money(total), serif: true),
                ],
              ),
            ),
            Text(
              '${rows.length} ${rows.length == 1 ? 'entry' : 'entries'}',
              style: context.text.labelMedium?.copyWith(
                color: c.textSecondary,
                fontFeatures: tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _summaryLabel() => switch (_dateRange) {
        _DateRange.today => 'Total today',
        _DateRange.week => 'Total this week',
        _DateRange.month => 'Total this month',
        _DateRange.year => 'Total this year',
        _DateRange.all => 'Total',
        _DateRange.custom => 'Total in range',
      };
}

enum _DateRange { today, week, month, year, all, custom }

extension _DateRangeLabel on _DateRange {
  String get label => switch (this) {
        _DateRange.today => 'Today',
        _DateRange.week => 'Week',
        _DateRange.month => 'Month',
        _DateRange.year => 'Year',
        _DateRange.all => 'All',
        _DateRange.custom => 'Custom',
      };
}

enum _ExportFormat { csv, pdf }

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 80, AppTheme.screenPad, 0),
      children: [
        EmptyState(title: "That didn't load", message: message),
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

  // For modules with cfg.principalAccount: the account the initial amount was
  // transferred from/to (creation only). Null = don't touch any balance.
  List<String> _accountNames = [];
  String? _principalAccount;

  // For modules with cfg.principalAccountField: the account the entered amount
  // was paid from (creation only, optional). Null = don't touch any balance.
  String? _paidFromAccount;

  EntityConfig get cfg => widget.config;
  bool get _isEdit => widget.existing != null;

  /// Whether the create form should offer a "which account?" picker that posts
  /// the principal as a cash movement. Edits never re-post, to avoid double
  /// counting an already-recorded transfer.
  bool get _showPrincipalAccount => cfg.principalAccount && !_isEdit;

  /// Whether the create form should offer the optional "paid from account"
  /// picker that deducts [EntityConfig.principalAccountField] from the chosen
  /// account. Edits never re-post, to avoid double counting.
  bool get _showPaidFromAccount =>
      cfg.principalAccountField != null && !_isEdit;

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
    if (_showPrincipalAccount || _showPaidFromAccount) {
      final accounts =
          _dynamicOptions['accounts'] ?? await _accountNamesFromRepo(repo);
      _accountNames = accounts;
    }
    if (mounted) setState(() {});
  }

  Future<List<String>> _accountNamesFromRepo(FinanceRepository repo) async {
    final rows = await repo.list('accounts');
    return rows
        .map((r) => (r['name'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
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
        // Settle-able rows: snapshot the full amount owed (so progress can be
        // shown as it's paid down) and start in the 'open' state.
        if (cfg.originalAmountField != null) {
          values[cfg.originalAmountField!] = values['amount'];
        }
        if (cfg.statusField != null) {
          values[cfg.statusField!] = 'open';
        }
        // Seed the running-total column from the first contribution.
        final cum = cfg.cumulativeIncrementField;
        final inc = cfg.incrementField;
        if (cum != null && inc != null) {
          values[cum] = values[inc];
        }
        await repo.insert(cfg.table, values);
        // Record the initial transfer against the chosen account, if any.
        // Debtor (paymentInflow) = money OUT (you lent); creditor = money IN.
        if (_showPrincipalAccount && _principalAccount != null) {
          final principal = (values['amount'] as num?)?.toDouble() ?? 0;
          if (principal != 0) {
            await repo.insert('cash_moves', {
              'account': _principalAccount,
              'amount': cfg.paymentInflow ? -principal : principal,
              'date': isoDate(DateTime.now()),
              'note': cfg.title,
            });
          }
        }
        // Optional "paid from account": deduct the configured field's value as
        // money OUT of the chosen account (e.g. cash spent buying an asset).
        if (_showPaidFromAccount && _paidFromAccount != null) {
          final spent =
              (values[cfg.principalAccountField!] as num?)?.toDouble() ?? 0;
          if (spent != 0) {
            await repo.insert('cash_moves', {
              'account': _paidFromAccount,
              'amount': -spent,
              'date': isoDate(DateTime.now()),
              'note': cfg.title,
            });
          }
        }
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
    final c = context.colors;
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            AppTheme.screenPad, 12, AppTheme.screenPad, bottomInset + 24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
              Text(
                '${_isEdit ? 'Edit' : 'Add'} ${cfg.title.toLowerCase()}',
                style: context.text.headlineSmall,
              ),
              const SizedBox(height: 18),
              ...cfg.fields.map(_buildField),
              if (_showPrincipalAccount && _accountNames.isNotEmpty)
                _buildPrincipalAccountPicker(),
              if (_showPaidFromAccount && _accountNames.isNotEmpty)
                _buildPaidFromAccountPicker(),
              if (_error != null) ...[
                const SizedBox(height: 4),
                Text(
                  _error!,
                  style: context.text.labelMedium?.copyWith(color: c.negative),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: OutlinedButton(
                      onPressed:
                          _busy ? null : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.onButtonFill,
                              ),
                            )
                          : Text(_isEdit
                              ? 'Update ${cfg.title.toLowerCase()}'
                              : 'Save ${cfg.title.toLowerCase()}'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Required account picker shown on the debtor/creditor create form. The
  /// chosen account's balance moves: money out of it (debtor — you lent) or
  /// into it (creditor — you borrowed). Shown only when accounts exist.
  Widget _buildPrincipalAccountPicker() {
    final label = cfg.paymentInflow
        ? 'Paid from account' // debtor: you lent this money
        : 'Received in account'; // creditor: you borrowed this money
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: _principalAccount,
        decoration: InputDecoration(labelText: label),
        items: _accountNames
            .map((a) => DropdownMenuItem(value: a, child: Text(a)))
            .toList(),
        onChanged: (v) => setState(() => _principalAccount = v),
        validator: (v) =>
            (v == null || v.isEmpty) ? 'Select an account' : null,
      ),
    );
  }

  /// Optional account picker shown on a create form for modules with
  /// [EntityConfig.principalAccountField]. Choosing an account deducts the
  /// entered field value from its balance; leaving it blank touches nothing.
  Widget _buildPaidFromAccountPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: _paidFromAccount,
        decoration:
            const InputDecoration(labelText: 'Paid from account (optional)'),
        items: [
          const DropdownMenuItem(value: null, child: Text('— None —')),
          ..._accountNames
              .map((a) => DropdownMenuItem(value: a, child: Text(a))),
        ],
        onChanged: (v) => setState(() => _paidFromAccount = v),
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
        child = FormField<DateTime>(
          initialValue: _dates[f.key],
          validator: f.required
              ? (v) => v == null ? 'Required' : null
              : null,
          builder: (state) {
            final d = _dates[f.key];
            return InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: d ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _dates[f.key] = picked);
                  state.didChange(picked);
                }
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: f.label,
                  errorText: state.errorText,
                ),
                child: Text(d == null ? 'Select date' : isoDate(d)),
              ),
            );
          },
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
