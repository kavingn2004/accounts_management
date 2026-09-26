import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/components.dart';
import '../../core/formatters.dart';
import '../../core/theme.dart';
import '../../data/finance_repository.dart';
import '../../data/history.dart';
import '../../data/module_event.dart';
import '../../data/nav_api.dart';
import '../../models/field_spec.dart';
import '../../services/providers.dart';
import '../../data/finance_math.dart';
import '../../services/quotes/investment_sync.dart';
import '../../services/redemption_service.dart';
import '../../services/sip_service.dart';
import '../investments/fund_picker.dart';
import '../history/history_label.dart';
import '../investments/sip_screen.dart';
import 'export_service.dart';
import 'module_dashboard.dart';

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

/// Newest `date` first. Rows on the same day keep the most recently added one
/// on top (by `created_at`, then by the repository's newest-first order), and
/// rows with no readable date sink to the bottom rather than vanish.
@visibleForTesting
List<Json> sortRowsByDateDesc(List<Json> rows) {
  final keyed = [
    for (var i = 0; i < rows.length; i++)
      (i: i, row: rows[i], day: _rowDay(rows[i]['date'])),
  ];
  keyed.sort((a, b) {
    if (a.day != b.day) {
      if (a.day == null) return 1;
      if (b.day == null) return -1;
      return b.day!.compareTo(a.day!);
    }
    final ca = a.row['created_at']?.toString() ?? '';
    final cb = b.row['created_at']?.toString() ?? '';
    final byCreated = cb.compareTo(ca);
    return byCreated != 0 ? byCreated : a.i.compareTo(b.i);
  });
  return [for (final k in keyed) k.row];
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
  Future<List<Json>> _events = Future.value(const []);
  List<String> _accountNames = [];

  /// Result of the last price refresh, or null when the module isn't live
  /// tracked and nothing has been fetched.
  SyncOutcome? _sync;

  /// Result of the last SIP ledger refresh: what was generated, what is stale,
  /// and which installments are waiting on a cash decision.
  SipRefreshOutcome? _sip;

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
  List<Json> _applyFilter(List<Json> rows) {
    final kept =
        cfg.dateFiltered ? filterRowsByDate(rows, _activeRange()) : rows;
    // Date-ordered modules (income, expenses, transfers) read newest-first by
    // the date on the entry, not by when it happened to be typed in.
    return cfg.orderBy == 'date' ? sortRowsByDateDesc(kept) : kept;
  }

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

  /// Run [body] as one History entry, so every write it makes can be undone
  /// together from the History screen.
  Future<void> _record(String verb, Json row, Future<void> Function() body) =>
      recordAction(
        ref.read(repoProvider),
        label: historyLabel(cfg, verb, row),
        table: cfg.table,
        body: body,
      );

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

  void _reload({bool forcePrices = false}) {
    final repo = ref.read(repoProvider);
    // Only modules with a dashboard read the ledger — every other page would
    // be paying for a table it never looks at.
    //
    // Failure is swallowed here rather than at the FutureBuilder: a Supabase
    // project that has not run migration 0005 has no `module_events` table at
    // all, and the resulting error would otherwise go unhandled while the rows
    // future is still loading. A missing ledger costs the chart its history,
    // which the empty state already accounts for — it must not take the page
    // down with it.
    _events = cfg.dashboard == null
        ? Future.value(const [])
        : repo
            .list(moduleEventsTable)
            .catchError((_) => const <Json>[]);

    final rows = repo.list(cfg.table, orderBy: cfg.orderBy, ascending: false);
    _future = cfg.liveTracked ? _withLivePrices(rows, forcePrices) : rows;
  }

  /// Reprice live-tracked rows before the list paints, so a value and its
  /// price never appear a beat apart.
  ///
  /// Prices are an enhancement over stored data, never a precondition for it:
  /// any failure here is caught and the rows are returned exactly as the
  /// repository gave them. A rate-limited API must not empty the screen.
  Future<List<Json>> _withLivePrices(
      Future<List<Json>> pending, bool force) async {
    final rows = await pending;

    // Order matters: the SIP engine settles how many units are held, then the
    // sync prices them. Running it the other way would value a SIP against
    // yesterday's unit count on the day an installment lands.
    //
    // The two are caught separately on purpose. They fail for unrelated
    // reasons — a NAV outage has nothing to do with a stock quote — and one
    // shared catch would let a broken SIP silently stop every other row on the
    // screen from being priced.
    try {
      final sip = await ref.read(sipServiceProvider).refresh(rows, force: force);
      if (mounted) setState(() => _sip = sip);
    } catch (_) {
      // Deliberately swallowed — see above.
    }

    try {
      final outcome = await ref.read(investmentSyncProvider).run(
            rows,
            events: await _events,
            force: force,
          );
      if (mounted) setState(() => _sync = outcome);
    } catch (_) {
      // Deliberately swallowed — see above.
    }
    return rows;
  }

  /// Reload the list.
  ///
  /// [force] bypasses the price throttle, and is reserved for a pull-to-refresh
  /// — an explicit request for fresh figures. Reloading after an edit or on
  /// returning from a detail screen is not one: it would download NAV again
  /// for data that cannot have moved since the last look.
  Future<void> _refresh({bool force = true}) async {
    setState(() => _reload(forcePrices: force));
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
    await _refresh(force: false);
    if (cfg.liveTracked) _reportPriceCheck();
  }

  /// Sell out of a holding and put the proceeds into an account.
  ///
  /// Units and amount are kept in step as you type either one, because the two
  /// ways people think about selling — "sell 50 units" and "take ₹5,000 out" —
  /// are the same action, and making someone do the arithmetic invites a typo
  /// into a figure that moves real money.
  Future<void> _redeem(Json row) async {
    final price = RedemptionService.unitPrice(row);
    final held = (row['quantity'] as num?)?.toDouble() ?? 0;
    final value = investmentValue(row);
    if (value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This holding has nothing to redeem')),
      );
      return;
    }

    final unitsCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    String? account = _accountNames.isNotEmpty ? _accountNames.first : null;
    String? error;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          void syncFromUnits(String v) {
            if (price == null) return;
            final u = double.tryParse(v.trim());
            setSt(() => amountCtrl.text =
                u == null ? '' : (u * price).toStringAsFixed(2));
          }

          void syncFromAmount(String v) {
            if (price == null) return;
            final a = double.tryParse(v.trim());
            setSt(() => unitsCtrl.text =
                a == null ? '' : (a / price).toStringAsFixed(3));
          }

          return AlertDialog(
            title: const Text('Redeem'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  price == null
                      ? 'Worth ${money(value)}'
                      : 'Holding ${quantityText(held)} at ${money(price)} '
                          '— worth ${money(value)}',
                  style: context.text.labelMedium
                      ?.copyWith(color: context.colors.textSecondary),
                ),
                const SizedBox(height: 12),
                if (price != null) ...[
                  TextField(
                    controller: unitsCtrl,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Units'),
                    onChanged: syncFromUnits,
                  ),
                  const SizedBox(height: 10),
                ],
                TextField(
                  controller: amountCtrl,
                  autofocus: price == null,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  decoration: const InputDecoration(labelText: 'Amount'),
                  onChanged: syncFromAmount,
                ),
                if (price != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        unitsCtrl.text = quantityText(held);
                        syncFromUnits(unitsCtrl.text);
                      },
                      child: const Text('Redeem all'),
                    ),
                  ),
                if (_accountNames.isNotEmpty)
                  _accountPicker('Credit to account', account,
                      (v) => setSt(() => account = v)),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!,
                      style: context.text.labelMedium
                          ?.copyWith(color: context.colors.negative)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final proceeds =
                      double.tryParse(amountCtrl.text.trim()) ?? 0;
                  final units = double.tryParse(unitsCtrl.text.trim()) ?? 0;
                  if (proceeds <= 0) {
                    setSt(() => error = 'Enter an amount to redeem');
                    return;
                  }
                  if (units > held + 1e-9) {
                    setSt(() => error = 'You hold fewer units than that');
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: const Text('Redeem'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await _record(
        'Redeemed',
        row,
        () => ref.read(redemptionServiceProvider).redeem(
              row,
              units: double.tryParse(unitsCtrl.text.trim()) ?? 0,
              proceeds: double.tryParse(amountCtrl.text.trim()) ?? 0,
              account: account,
            ),
      );
    } on RedemptionError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    await _refresh(force: false);
  }

  /// Raise or lower the installment amount from a chosen date onward.
  ///
  /// Not a plain edit of the amount: installments are derived from it, so
  /// changing it outright would restate every past debit at the new figure and
  /// overstate what was actually invested. The change is dated instead, and
  /// history keeps the amounts that were really paid.
  Future<void> _changeSipAmount(Json row) async {
    final current = (row[SipFields.amount] as num?)?.toDouble() ?? 0;
    final controller = TextEditingController();
    var from = DateTime.now();

    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Change SIP amount'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Currently ${money(current)} per installment. Installments '
                'before the date below keep the amount they were paid at.',
                style: context.text.labelSmall
                    ?.copyWith(color: context.colors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(labelText: 'New amount'),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: from,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setSt(() => from = picked);
                },
                child: InputDecorator(
                  decoration:
                      const InputDecoration(labelText: 'Effective from'),
                  child: Text(isoDate(from)),
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
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (amount == null || amount <= 0) return;

    await _record(
      'Changed SIP amount of',
      row,
      () => ref
          .read(sipServiceProvider)
          .changeAmount(row, amount: amount, from: from),
    );
    await _refresh(force: false);
  }

  /// Record a one-off purchase outside the schedule. Units are allotted at the
  /// NAV for the date given, exactly as a scheduled installment would be.
  Future<void> _addLumpsum(Json row) async {
    final controller = TextEditingController();
    var date = DateTime.now();
    String? account;

    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Add lumpsum'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(labelText: 'Amount'),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setSt(() => date = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Purchase date'),
                  child: Text(isoDate(date)),
                ),
              ),
              if (_accountNames.isNotEmpty)
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
    if (amount == null || amount <= 0 || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    var failed = false;
    await _record('Added lumpsum to', row, () async {
      try {
        await ref.read(sipServiceProvider).addLumpsum(
              row,
              date: date,
              amount: amount,
              account: account,
            );
      } catch (e) {
        // Without the ledger table there is nowhere to record a purchase, and a
        // lumpsum that silently vanishes is worse than one that is refused.
        messenger.showSnackBar(SnackBar(
          content: Text(
            e.toString().contains(SipFields.table)
                ? 'Cannot record a lumpsum yet — run the sip_installments '
                    'migration. Scheduled installments still value correctly.'
                : 'Could not record the lumpsum: $e',
          ),
        ));
        failed = true;
        return;
      }
      if (account != null) await _recordCashMove(account!, -amount);
    });
    if (failed) return;
    await _refresh(force: false);
  }

  /// Post the cash for a due SIP installment.
  ///
  /// Units were counted the moment the installment was generated; this only
  /// records where the money came from. `cash_posted` is set in the same step,
  /// so a repeated refresh can never debit an account twice.
  Future<void> _confirmInstallment(Json due) async {
    final amount = (due[InstallmentFields.amount] as num?)?.toDouble() ?? 0;
    final suggested = (due['suggested_account'] ?? '').toString();
    var account = _accountNames.contains(suggested)
        ? suggested
        : (_accountNames.isNotEmpty ? _accountNames.first : null);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Confirm installment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${due['parent_name']} · '
                '${prettyDate(due[InstallmentFields.date]?.toString())}',
                style: context.text.bodyMedium,
              ),
              const SizedBox(height: 6),
              MoneyText(money(amount), style: context.text.titleLarge),
              if (_accountNames.isNotEmpty) ...[
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: account,
                  decoration:
                      const InputDecoration(labelText: 'Debit from account'),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('— Don\'t record cash —')),
                    ..._accountNames.map(
                        (a) => DropdownMenuItem(value: a, child: Text(a))),
                  ],
                  onChanged: (v) => setSt(() => account = v),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    final repo = ref.read(repoProvider);
    await recordAction(
      repo,
      label: 'Posted ${due['parent_name'] ?? ''} SIP installment',
      table: cfg.table,
      body: () async {
        await repo.update(SipFields.table, due['id'].toString(), {
          InstallmentFields.cashPosted: true,
          if (account != null) InstallmentFields.account: account,
        });
        if (account != null && amount > 0) {
          await repo.insert('cash_moves', {
            'account': account,
            'amount': -amount, // a SIP debit is money out
            'date': due[InstallmentFields.date],
            'note': '${due['parent_name']} SIP',
          });
        }
      },
    );
    await _refresh();
  }

  /// Mark a due installment as not taken — it keeps its place in the ledger,
  /// struck through, but stops counting towards units or invested capital.
  Future<void> _skipInstallment(Json due) async {
    final repo = ref.read(repoProvider);
    await recordAction(
      repo,
      label: 'Skipped ${due['parent_name'] ?? ''} SIP installment',
      table: cfg.table,
      body: () => repo.update(
        SipFields.table,
        due['id'].toString(),
        {InstallmentFields.skipped: true, InstallmentFields.units: 0},
      ),
    );
    await _refresh();
  }

  /// Confirm what a just-saved symbol resolved to.
  ///
  /// Without this a mistyped ticker looks identical to a correct one: the row
  /// saves, nothing happens, and the value silently never updates again. The
  /// save itself is never blocked — a row with a bad symbol is still a row.
  void _reportPriceCheck() {
    final outcome = _sync;
    if (outcome == null || outcome.isIdle || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    if (outcome.failures.isNotEmpty) {
      final first = outcome.failures.entries.first;
      final more = outcome.failures.length - 1;
      messenger.showSnackBar(SnackBar(
        content: Text('${first.key}: ${first.value}'
            '${more > 0 ? ' (and $more more)' : ''}'),
      ));
      return;
    }
    if (outcome.priced.length == 1) {
      final p = outcome.priced.first;
      messenger.showSnackBar(SnackBar(
        content: Text('${p.name}: ${money(p.price)} × '
            '${quantityText(p.quantity)} = ${money(p.value)} · ${p.source}'),
      ));
    } else if (outcome.priced.isNotEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text('${outcome.priced.length} holdings repriced'),
      ));
    }
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
    final repo = ref.read(repoProvider);
    final id = row['id'].toString();
    // One History entry for the row and its children, so undo brings the
    // whole thing back.
    await _record('Deleted', row, () async {
      await repo.delete(cfg.table, id);

      // Children go with the parent. Left behind, a ledger keyed on a row that
      // no longer exists is unreachable from the UI and grows forever.
      for (final table in [...cfg.cascadeTables, moduleEventsTable]) {
        try {
          final children = await repo.list(table);
          for (final child in children) {
            if ((child['parent_id'] ?? '').toString() != id) continue;
            await repo.delete(table, child['id'].toString());
          }
        } catch (_) {
          // A table that does not exist has nothing to clean up.
        }
      }
    });
    await _refresh(force: false);
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
    await _record('Added money to', row, () async {
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
    });
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
    await _record('Updated value of', row, () async {
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
    });
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
                decoration: InputDecoration(
                    // "Withdraw amount" for savings, "Payment amount" for a
                    // debt — the same dialog serves both.
                    labelText: '${cfg.decrementLabel ?? 'Payment'} amount',
                    prefixText: '- '),
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
              child: Text(cfg.decrementConfirm ?? 'Pay'),
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
    await _record(cfg.paymentInflow ? 'Received from' : 'Paid', row, () async {
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
    });
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
    await _record('Settled', row, () async {
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
    });
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
    await _record(
      'Reopened',
      row,
      () => ref
          .read(repoProvider)
          .update(cfg.table, row['id'].toString(), updates),
    );
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
          if (_showFilterBar) _buildFilterBar(),
          if (cfg.liveTracked &&
              _sync != null &&
              _sync!.failures.isNotEmpty)
            _PriceNotice(outcome: _sync!),
          if (_sip != null && _sip!.errors.isNotEmpty)
            _SipErrorNotice(errors: _sip!.errors),
          if (_sip != null && _sip!.unsaved.isNotEmpty)
            _UnsavedHistoryNotice(unsaved: _sip!.unsaved),
          if (_sip != null && _sip!.stale.isNotEmpty)
            _StaleNavNotice(stale: _sip!.stale),
          if (_sip != null && _sip!.dueForConfirmation.isNotEmpty)
            _DueInstallmentBanner(
              due: _sip!.dueForConfirmation,
              onConfirm: _confirmInstallment,
              onSkip: _skipInstallment,
            ),
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
                  return _buildList(rows, allRows);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Every module with a dashboard gets the range chips, not just the ones
  /// whose rows carry a `date`. On a dateless module the chips move the
  /// dashboard alone — `_applyFilter` still returns the list untouched.
  bool get _showFilterBar => cfg.dateFiltered || cfg.dashboard != null;

  /// The dashboard header followed by the rows (or the empty state).
  ///
  /// All one scrollable, deliberately. A header pinned above an Expanded list
  /// competes with it for a fixed screen: a four-stat dashboard with a chart
  /// and a breakdown is taller than the remaining space on a small phone, and
  /// the list gets squeezed to a few pixels. Scrolling it away is also what
  /// makes the collapse control a convenience rather than a necessity.
  Widget _buildList(List<Json> rows, List<Json> allRows) {
    final range = _activeRange();
    final header = cfg.dashboard == null
        ? null
        : FutureBuilder<List<Json>>(
            future: _events,
            builder: (context, evSnap) => ModuleDashboard(
              config: cfg,
              rows: rows,
              events: evSnap.data ?? const [],
              rangeStart: range?.start,
              rangeEnd: range?.end,
            ),
          );

    if (rows.isEmpty) {
      final inRange = allRows.isNotEmpty && cfg.dateFiltered;
      return ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          if (header != null) header,
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.screenPad, 24, AppTheme.screenPad, 0),
            child: EmptyState(
              title: inRange
                  ? 'Nothing in this range'
                  : 'No ${cfg.title.toLowerCase()} yet',
              message: inRange
                  ? 'Widen the filter, or add an entry with the + button.'
                  : 'Tap + to record your first entry.',
            ),
          ),
        ],
      );
    }

    final headerCount = header == null ? 0 : 1;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: rows.length + headerCount,
      itemBuilder: (context, i) {
        if (header != null && i == 0) return header;
        final index = i - headerCount;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.screenPad),
          child: _buildRow(
            context,
            rows[index],
            isLast: index == rows.length - 1,
          ),
        );
      },
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
        onTap: cfg.readOnly ? null : () => _openRow(r),
        child: row,
      ),
    );
  }

  /// A SIP has more to say than an edit form can hold — its ledger is where its
  /// value comes from — so tapping one opens the detail screen and editing
  /// moves to the row menu. Every other row behaves as before.
  Future<void> _openRow(Json r) async {
    if (SipService.isSip(r)) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SipScreen(row: r)),
      );
      await _refresh(force: false);
      return;
    }
    await _openSheet(existing: r);
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
        } else if (v == 'redeem') {
          _redeem(r);
        } else if (v == 'lumpsum') {
          _addLumpsum(r);
        } else if (v == 'step_up') {
          _changeSipAmount(r);
        } else if (v == 'pause') {
          final pausing = r[SipFields.active] != false;
          await _record(
            pausing ? 'Paused' : 'Resumed',
            r,
            () => ref.read(repoProvider).update(cfg.table, r['id'].toString(),
                {SipFields.active: !pausing}),
          );
          await _refresh();
        } else if (v == 'delete') {
          if (await _confirmDelete(r)) _delete(r);
        }
      },
      itemBuilder: (_) => [
        // A SIP's units come from its ledger, so the generic add/set actions
        // would fight the engine. It gets its own instead.
        if (SipService.isSip(r)) ...[
          _menuItem('lumpsum', Icons.add_circle_outline, 'Add lumpsum',
              cfg.tone.of(context)),
          _menuItem('step_up', Icons.trending_up, 'Change SIP amount',
              cfg.tone.of(context)),
          _menuItem(
              'pause',
              r[SipFields.active] == false
                  ? Icons.play_arrow_outlined
                  : Icons.pause_outlined,
              r[SipFields.active] == false ? 'Resume SIP' : 'Pause SIP',
              c.textSecondary),
        ],
        // Selling out: the only way money comes back from an investment.
        if (cfg.redeemable)
          _menuItem('redeem', Icons.south_west, 'Redeem', c.positive),
        if (cfg.incrementField != null && !SipService.isSip(r))
          _menuItem('add_amount', Icons.add_circle_outline,
              cfg.incrementLabel ?? 'Add amount', cfg.tone.of(context)),
        if (cfg.setField != null && !SipService.isSip(r))
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

/// Valued correctly, but the installment history has nowhere to live.
///
/// Deliberately quiet — a bordered strip rather than the red one — because
/// nothing on screen is wrong. Only the ability to edit history is missing,
/// and saying "could not be valued" over a correct figure is a lie that sends
/// people looking for a problem they don't have.
class _UnsavedHistoryNotice extends StatelessWidget {
  const _UnsavedHistoryNotice({required this.unsaved});
  final Map<String, String> unsaved;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final names = unsaved.keys.join(', ');
    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: 16, color: c.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Figures for $names are worked out from the schedule and are '
              'correct. ${unsaved.values.first}.',
              style: context.text.labelMedium?.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A SIP could not be valued at all: no NAV was reachable and none was cached,
/// so there are no units and no invested total to show.
///
/// This is louder than the stale notice because the row beneath it reads ₹0,
/// and an unexplained ₹0 looks like lost data rather than a missing download.
class _SipErrorNotice extends StatelessWidget {
  const _SipErrorNotice({required this.errors});
  final Map<String, String> errors;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final first = errors.entries.first;
    final more = errors.length - 1;

    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.negative),
        borderRadius: BorderRadius.circular(AppTheme.rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off_outlined, size: 16, color: c.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${first.key} could not be valued'
                  '${more > 0 ? ' (and $more more)' : ''}',
                  style: context.text.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  '${first.value}. Its NAV has never been downloaded, so it '
                  'holds no units yet — pull down to try again.',
                  style:
                      context.text.labelMedium?.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// NAV could not be refreshed, so valuations are running on an earlier day's
/// figures. Says so rather than passing an old NAV off as today's.
class _StaleNavNotice extends StatelessWidget {
  const _StaleNavNotice({required this.stale});
  final Map<String, String> stale;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final names = stale.keys.join(', ');
    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.history_toggle_off, size: 16, color: c.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'NAV for $names could not be refreshed — valued from the last '
              'published figure.',
              style: context.text.labelMedium?.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Installments that have fallen due since the row was created and are waiting
/// on a decision about the cash.
///
/// Units are already counted — this is only about which account paid. Skipping
/// is offered beside confirming so an installment that did not actually go
/// through can be dismissed without hunting for a menu.
class _DueInstallmentBanner extends StatelessWidget {
  const _DueInstallmentBanner({
    required this.due,
    required this.onConfirm,
    required this.onSkip,
  });

  final List<Json> due;
  final Future<void> Function(Json) onConfirm;
  final Future<void> Function(Json) onSkip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final first = due.first;
    final amount = (first[InstallmentFields.amount] as num?)?.toDouble() ?? 0;
    final more = due.length - 1;

    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 0, AppTheme.screenPad, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.rControl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_available, size: 16, color: c.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  due.length == 1
                      ? '1 SIP installment due'
                      : '${due.length} SIP installments due',
                  style: context.text.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(
              '${first['parent_name']} · '
              '${prettyDate(first[InstallmentFields.date]?.toString())} · '
              '${money(amount)}${more > 0 ? '  (+$more more)' : ''}',
              style: context.text.labelMedium?.copyWith(color: c.textSecondary),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => onSkip(first),
                child: Text('Skip',
                    style: TextStyle(color: c.textSecondary)),
              ),
              TextButton(
                onPressed: () => onConfirm(first),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Quiet strip explaining why some rows are not showing a live figure.
///
/// Deliberately not a dialog and not an error state: the values on screen are
/// still the last good ones, and the list stays fully usable. The browser case
/// gets its own wording because no amount of retrying will fix it.
class _PriceNotice extends StatelessWidget {
  const _PriceNotice({required this.outcome});
  final SyncOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final failures = outcome.failures;
    final first = failures.entries.first;
    final message = outcome.platformBlocked
        ? 'Live prices for this holding need the mobile app — a browser '
            'cannot reach the price service.'
        : failures.length == 1
            ? '${first.key}: ${first.value}'
            : '${failures.length} prices unavailable — '
                '${first.key}: ${first.value}';

    return Container(
      margin: const EdgeInsets.fromLTRB(AppTheme.screenPad, 0,
          AppTheme.screenPad, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.rControl),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: c.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$message Showing the last known value.',
              style:
                  context.text.labelMedium?.copyWith(color: c.textSecondary),
            ),
          ),
        ],
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

  /// Fund chosen in a [FieldType.fundSearch] field, by field key.
  final Map<String, SchemeRef> _schemes = {};

  /// Keys some other field's visibility or helper text reads. Typing in one of
  /// these has to rebuild the form; typing in any other field must not, or
  /// every keystroke anywhere would repaint the whole sheet.
  late final Set<String> _watched = {
    for (final f in cfg.fields) ...[
      if (f.hiddenWhenFilled != null) f.hiddenWhenFilled!,
      if (f.dependsOn != null) f.dependsOn!,
    ]
  };
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
        case FieldType.fundSearch:
          // Rebuilt from what was stored alongside the code, so editing a row
          // shows its fund without a network round trip.
          final code = current is num
              ? current.toInt()
              : int.tryParse((current ?? '').toString());
          if (code != null) {
            _schemes[f.key] = SchemeRef(
              code: code,
              name: (e?['scheme_name'] ?? 'Scheme $code').toString(),
            );
          }
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
        // A field the form is hiding has no say over the row. Writing it would
        // save whatever the user typed before switching type away from it.
        if (!_isVisible(f)) {
          values[f.key] = null;
          continue;
        }
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
          case FieldType.fundSearch:
            // Three keys from one field: the code identifies the scheme, the
            // names let the row describe itself with no lookup.
            final scheme = _schemes[f.key];
            values[f.key] = scheme?.code;
            values['scheme_name'] = scheme?.name;
            break;
        }
      }
      if (!_isEdit && cfg.seedOnCreate != null) {
        values.addAll(cfg.seedOnCreate!(values));
      }
      final repo = ref.read(repoProvider);
      await recordAction(
        repo,
        label: historyLabel(cfg, _isEdit ? 'Edited' : 'Added',
            _isEdit ? {...widget.existing!, ...values} : values),
        table: cfg.table,
        body: () async {
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
        },
      );
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
              for (var i = 0; i < cfg.fields.length; i++) ...[
                if (_sectionFor(i) != null) ...[
                  const SizedBox(height: 4),
                  SectionLabel(_sectionFor(i)!),
                  const SizedBox(height: 8),
                ],
                _buildField(cfg.fields[i]),
              ],
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

  /// The value the field's [FieldSpec.dependsOn] currently holds, as the form
  /// sees it right now — not as the row was saved.
  String _dependencyValue(FieldSpec f) {
    final key = f.dependsOn;
    if (key == null) return '';
    return (_selects[key] ?? _controllers[key]?.text ?? '').trim().toLowerCase();
  }

  bool _isVisible(FieldSpec f) {
    final blocker = f.hiddenWhenFilled;
    if (blocker != null &&
        (_controllers[blocker]?.text.trim().isNotEmpty ?? false)) {
      return false;
    }
    final value = _dependencyValue(f);
    if (f.hiddenWhen != null && f.hiddenWhen!.contains(value)) return false;
    return f.visibleWhen == null || f.visibleWhen!.contains(value);
  }

  /// The heading to draw above [f], or null when it belongs to the group
  /// already open. Sections are skipped when every field under them is hidden,
  /// so a heading never floats above nothing.
  String? _sectionFor(int index) {
    final f = cfg.fields[index];
    if (f.section == null || !_isVisible(f)) return null;
    for (var i = index - 1; i >= 0; i--) {
      final earlier = cfg.fields[i];
      if (!_isVisible(earlier)) continue;
      return earlier.section == f.section ? null : f.section;
    }
    return f.section;
  }

  /// Helper text for the current dependency value, falling back to the static
  /// hint when the field doesn't vary or the value has no entry.
  String? _hintFor(FieldSpec f) =>
      f.hints?[_dependencyValue(f)] ?? f.hint;

  Widget _buildField(FieldSpec f) {
    if (!_isVisible(f)) return const SizedBox.shrink();
    Widget child;
    switch (f.type) {
      case FieldType.text:
        child = TextFormField(
          controller: _controllers[f.key],
          decoration:
              InputDecoration(labelText: f.label, helperText: _hintFor(f)),
          validator: _req(f),
          onChanged: _watched.contains(f.key) ? (_) => setState(() {}) : null,
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
          decoration:
              InputDecoration(labelText: f.label, helperText: _hintFor(f)),
          validator: _req(f),
          onChanged: _watched.contains(f.key) ? (_) => setState(() {}) : null,
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
      case FieldType.fundSearch:
        final picked = _schemes[f.key];
        child = FormField<SchemeRef>(
          initialValue: picked,
          validator: f.required
              ? (v) => v == null ? 'Pick a fund' : null
              : null,
          builder: (state) => InkWell(
            onTap: () async {
              final scheme = await FundPicker.show(context);
              if (scheme == null) return;
              setState(() => _schemes[f.key] = scheme);
              state.didChange(scheme);
            },
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: f.label,
                errorText: state.errorText,
                helperText: picked == null ? _hintFor(f) : 'Scheme ${picked.code}',
                suffixIcon: const Icon(Icons.search, size: 20),
              ),
              child: Text(
                picked?.name ?? 'Search for your fund',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: picked == null
                    ? context.text.bodyLarge
                        ?.copyWith(color: context.colors.textSecondary)
                    : context.text.bodyLarge,
              ),
            ),
          ),
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
