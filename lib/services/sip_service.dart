import '../data/finance_repository.dart';
import '../data/nav_api.dart';
import '../data/nav_cache.dart';
import '../data/sip_math.dart';
import 'quotes/investment_sync.dart';

/// Storage keys for a SIP. Spelled once so the registry, the service and the
/// detail screen cannot drift apart.
class SipFields {
  const SipFields._();

  static const schemeCode = 'scheme_code';
  static const schemeName = 'scheme_name';
  static const fundHouse = 'fund_house';
  static const amount = 'sip_amount';
  static const frequency = 'sip_frequency';
  static const day = 'sip_day';
  static const startDate = 'sip_start_date';
  static const active = 'sip_active';

  /// Step-ups: `[{'from': 'YYYY-MM-DD', 'amount': n}, …]`, oldest first.
  ///
  /// A SIP's amount is not one number over its life — people raise it as they
  /// earn more. Editing [amount] alone would silently rewrite every past
  /// installment at the new figure, overstating what was actually invested, so
  /// each increase records the date it takes effect and the past is left alone.
  static const amountChanges = 'sip_amount_changes';

  /// The date this row was created — the boundary between backfilled history
  /// (units only) and live installments (which ask before moving cash).
  static const cashFrom = 'cash_from';

  /// The account the mandate debits. With it set, an installment posts its
  /// debit the moment it falls due, the way a bank mandate does. Without it the
  /// app has to ask, which is the due-installment banner.
  static const account = 'sip_account';

  static const table = 'sip_installments';
}

/// Storage keys on one `sip_installments` row.
class InstallmentFields {
  const InstallmentFields._();

  static const parentId = 'parent_id';
  static const date = 'date';
  static const amount = 'amount';
  static const nav = 'nav';
  static const navDate = 'nav_date';
  static const units = 'units';

  /// `auto` (generated from the schedule) or `manual` (lumpsum, hand-added).
  static const source = 'source';
  static const skipped = 'skipped';
  static const account = 'account';

  /// Why an installment was skipped, in the user's own words — "mandate
  /// bounced", "paused this month". A skipped row with no reason is a hole in
  /// the record six months later, when the totals no longer add up and nobody
  /// remembers why.
  static const note = 'note';

  /// Set once a `cash_moves` row exists for this installment. The guard that
  /// makes cash posting idempotent across repeated refreshes.
  static const cashPosted = 'cash_posted';
}

/// What one SIP refresh did.
class SipRefreshOutcome {
  const SipRefreshOutcome({
    this.rows = 0,
    this.created = 0,
    this.resolved = 0,
    this.dueForConfirmation = const [],
    this.stale = const {},
    this.errors = const {},
    this.unsaved = const {},
  });

  /// SIP rows examined.
  final int rows;

  /// Installments appended because they had become due.
  final int created;

  /// Previously unresolved installments that finally got a NAV.
  final int resolved;

  /// Installments dated on or after their row's `cash_from` that have not yet
  /// had cash confirmed against them.
  final List<Json> dueForConfirmation;

  /// Scheme name → why its NAV is older than today.
  final Map<String, String> stale;

  /// Scheme name → why it could not be valued at all.
  final Map<String, String> errors;

  /// Scheme name → why its history cannot be stored, even though the figures
  /// are correct. A different thing from [errors], and conflating the two tells
  /// someone their valued holding is broken.
  final Map<String, String> unsaved;

  bool get isIdle => rows == 0;
}

/// Generates and maintains a SIP's installment ledger.
///
/// The division of labour with [InvestmentSync] is deliberate: this service
/// owns *units* — how many were bought, on what date, at what NAV — and writes
/// them to the row's `quantity`. It never writes `current_value`. Valuation,
/// throttling and error handling stay in one place, on the other side of that
/// key, so there is only ever one writer per figure.
class SipService {
  SipService({
    required FinanceRepository repo,
    required NavCache navs,
    DateTime Function()? clock,
  })  : _repo = repo,
        _navs = navs,
        _now = clock ?? DateTime.now;

  final FinanceRepository _repo;
  final NavCache _navs;
  final DateTime Function() _now;

  static const investmentsTable = 'investments';

  /// True when a row is a SIP the engine should maintain.
  static bool isSip(Json row) =>
      (row[InvestmentFields.type] ?? '').toString().toLowerCase() == 'sip' &&
      schemeCodeOf(row) != null;

  /// The installment amount in force on [date].
  ///
  /// The base [SipFields.amount] applies until the first step-up, then each
  /// step-up applies from its own date onward.
  static double amountOn(Json row, DateTime date) {
    var amount = (row[SipFields.amount] as num?)?.toDouble() ?? 0;
    final changes = row[SipFields.amountChanges];
    if (changes is! List) return amount;

    final dated = <(DateTime, double)>[];
    for (final c in changes) {
      if (c is! Map) continue;
      final from = DateTime.tryParse((c['from'] ?? '').toString());
      final value = (c['amount'] as num?)?.toDouble();
      if (from != null && value != null && value > 0) {
        dated.add((SipMath.dayOf(from), value));
      }
    }
    dated.sort((a, b) => a.$1.compareTo(b.$1));
    final on = SipMath.dayOf(date);
    for (final change in dated) {
      if (!change.$1.isAfter(on)) amount = change.$2;
    }
    return amount;
  }

  /// Raise (or lower) the installment amount from [from] onward, leaving every
  /// installment before it untouched.
  Future<void> changeAmount(
    Json row, {
    required double amount,
    required DateTime from,
  }) async {
    final existing = (row[SipFields.amountChanges] as List?) ?? const [];
    final changes = [
      ...existing.whereType<Map>().map(Json.from),
      {'from': isoDay(from), 'amount': amount},
    ];
    final values = {
      SipFields.amountChanges: changes,
      // The headline figure follows the latest step-up, so the form and the
      // list show what is being debited now rather than what once was.
      SipFields.amount: amount,
    };
    await _repo.update(investmentsTable, row['id'].toString(), values);
    row.addAll(values);
  }

  static int? schemeCodeOf(Json row) {
    final raw = row[SipFields.schemeCode];
    if (raw is num) return raw.toInt();
    return int.tryParse((raw ?? '').toString().trim());
  }

  /// Bring every SIP row up to date: append newly due installments, resolve any
  /// that were left without a NAV, and write units back to the row.
  ///
  /// A scheme whose NAV cannot be refreshed is reported through
  /// [SipRefreshOutcome.stale] and still valued from cached history — the last
  /// published NAV is a far better answer than none.
  Future<SipRefreshOutcome> refresh(
    List<Json> rows, {
    bool force = false,
  }) async {
    final sips = rows.where(isSip).toList();
    if (sips.isEmpty) return const SipRefreshOutcome();

    final ledger = await _readLedger();
    final stale = <String, String>{};
    final errors = <String, String>{};
    final unsaved = <String, String>{};
    final due = <Json>[];
    var created = 0;
    var resolved = 0;

    for (final row in sips) {
      final code = schemeCodeOf(row)!;
      final label = (row['name'] ?? 'SIP').toString();

      CachedNav cached;
      try {
        cached = await _navs.series(code, force: force);
      } on NavException catch (e) {
        errors[label] = e.message;
        continue;
      }
      if (cached.isStale) {
        stale[label] = cached.error ?? 'NAV could not be refreshed';
      }

      final existing = ledger
          .where((e) =>
              (e[InstallmentFields.parentId] ?? '').toString() ==
              row['id'].toString())
          .toList();

      try {
        final outcome = await _reconcile(row, existing, cached.series);
        created += outcome.$1;
        resolved += outcome.$2;
        due.addAll(outcome.$3);
      } catch (e) {
        // The ledger could not be written — most often because the table does
        // not exist yet. That table PERSISTS installments; it does not invent
        // them. The schedule and the NAV history already say what was bought
        // and when, so derive the same figures in memory and value the holding
        // anyway. What is lost is the ability to edit history — skipping an
        // installment, correcting units — not the value itself.
        try {
          final derived = derive(row, cached.series, now: _now());
          await _writeUnits(row, derived);
          // Valued correctly — the only casualty is editable history.
          unsaved[label] = _ledgerMessage(e);
        } catch (_) {
          errors[label] = _ledgerMessage(e);
        }
      }
    }

    return SipRefreshOutcome(
      rows: sips.length,
      created: created,
      resolved: resolved,
      dueForConfirmation: due,
      stale: stale,
      errors: errors,
      unsaved: unsaved,
    );
  }

  /// Backfill a newly created SIP and write its opening units.
  ///
  /// Called once, on creation, so the row shows a real value immediately
  /// instead of waiting for the next refresh.
  Future<SipRefreshOutcome> backfill(Json row) => refresh([row]);

  /// Append a one-off purchase outside the schedule.
  Future<void> addLumpsum(Json row, {
    required DateTime date,
    required double amount,
    String? account,
  }) async {
    final code = schemeCodeOf(row);
    if (code == null) return;
    NavSeries? series;
    try {
      series = (await _navs.series(code)).series;
    } on NavException {
      series = _navs.peek(code);
    }

    await _repo.insert(SipFields.table, {
      InstallmentFields.parentId: row['id'].toString(),
      InstallmentFields.date: isoDay(date),
      InstallmentFields.amount: amount,
      InstallmentFields.source: 'manual',
      if (account != null) InstallmentFields.account: account,
      ...(series == null ? {} : _allotment(date, amount, series)),
    });
    await _rewriteUnits(row);
  }

  /// Generate what is missing, resolve what can now be resolved, and write the
  /// row's units. Returns (created, resolved, dueForConfirmation).
  Future<(int, int, List<Json>)> _reconcile(
    Json row,
    List<Json> existing,
    NavSeries series,
  ) async {
    final today = SipMath.dayOf(_now());
    var created = 0;
    var resolved = 0;

    final start = DateTime.tryParse((row[SipFields.startDate] ?? '').toString());
    final amount = (row[SipFields.amount] as num?)?.toDouble() ?? 0;
    final isActive = row[SipFields.active] != false;

    // A paused SIP stops generating, but keeps valuing — the units it already
    // bought still exist.
    if (start != null && amount > 0 && isActive) {
      final have = {
        for (final e in existing)
          if ((e[InstallmentFields.source] ?? 'auto') == 'auto')
            (e[InstallmentFields.date] ?? '').toString()
      };

      final schedule = SipMath.generateSchedule(
        start: start,
        frequency: sipFrequencyFrom(row[SipFields.frequency]),
        day: (row[SipFields.day] as num?)?.toInt() ?? start.day,
        through: today,
        notBefore: series.earliest,
      );

      for (final date in schedule) {
        if (have.contains(isoDay(date))) continue; // never duplicate
        final due = amountOn(row, date);
        final record = {
          InstallmentFields.parentId: row['id'].toString(),
          InstallmentFields.date: isoDay(date),
          InstallmentFields.amount: due,
          InstallmentFields.source: 'auto',
          ..._allotment(date, due, series),
        };
        await _repo.insert(SipFields.table, record);
        existing.add(record);
        created++;
      }
    }

    // Freshly inserted rows have no id until the ledger is read back, and an
    // installment with no id cannot be confirmed, skipped or corrected. Re-read
    // so a SIP that just generated one can act on it in the same pass rather
    // than a refresh later.
    if (created > 0) {
      final reread = await _readLedger();
      final mine = reread
          .where((e) =>
              (e[InstallmentFields.parentId] ?? '').toString() ==
              row['id'].toString())
          .toList();
      if (mine.isNotEmpty) {
        existing
          ..clear()
          ..addAll(mine);
      }
    }

    // Installments generated on a day the NAV had not caught up to yet.
    for (final e in existing) {
      if (e[InstallmentFields.nav] != null) continue;
      final date = DateTime.tryParse((e[InstallmentFields.date] ?? '').toString());
      if (date == null) continue;
      final allotment = _allotment(
          date, (e[InstallmentFields.amount] as num?)?.toDouble() ?? 0, series);
      if (allotment.isEmpty) continue;
      final id = e['id']?.toString();
      if (id != null) await _repo.update(SipFields.table, id, allotment);
      e.addAll(allotment);
      resolved++;
    }

    // A configured mandate debits by itself; without one the caller is asked.
    final account = (row[SipFields.account] ?? '').toString().trim();
    if (account.isNotEmpty) {
      final floor = cashBoundary(row);
      for (final entry in existing) {
        if (entry[InstallmentFields.cashPosted] == true) continue;
        if (entry[InstallmentFields.skipped] == true) continue;
        final date =
            DateTime.tryParse((entry[InstallmentFields.date] ?? '').toString());
        if (date == null || date.isBefore(floor)) continue;
        await _postDebit(row, entry, account);
      }
    }

    await _writeUnits(row, existing);
    return (created, resolved, _dueFor(row, existing));
  }

  /// NAV, its date, and the units bought — empty when nothing is published
  /// within the forward window, so the installment stays flagged for attention.
  Json _allotment(DateTime date, double amount, NavSeries series) =>
      _allotmentFor(date, amount, series);

  /// Installments at or after the cash boundary with no cash posted yet.
  ///
  /// The boundary is a stored date rather than an implicit "now", so backfilled
  /// history never asks to move money that was already spent months ago.
  List<Json> _dueFor(Json row, List<Json> installments) {
    final floor = cashBoundary(row);

    // Whatever account this SIP was last debited from, offered as the default
    // so confirming a monthly installment is one tap.
    String? lastAccount;
    for (final e in installments) {
      final account = (e[InstallmentFields.account] ?? '').toString();
      if (account.isNotEmpty) lastAccount = account;
    }

    return [
      for (final e in installments)
        // An installment inserted moments ago has no id until the ledger is
        // re-read; it surfaces on the next refresh rather than offering an
        // action that cannot address it.
        if (e['id'] != null &&
            e[InstallmentFields.cashPosted] != true &&
            e[InstallmentFields.skipped] != true)
          if (DateTime.tryParse((e[InstallmentFields.date] ?? '').toString())
                  ?.isBefore(floor) ==
              false)
            {
              ...e,
              'parent_name': (row['name'] ?? 'SIP').toString(),
              if (lastAccount != null) 'suggested_account': lastAccount,
            },
    ];
  }

  /// The date from which installments move real money.
  ///
  /// Before it, installments are backfilled history whose debits were already
  /// recorded by hand, so posting them again would double-count. On or after
  /// it, they are live.
  ///
  /// A row with no stored boundary falls back to when it was created, and
  /// finally to today. It must never fall back to "never": that silently
  /// disabled cash posting for the life of the row, which is the bug this
  /// replaces.
  DateTime cashBoundary(Json row) {
    final stored = DateTime.tryParse((row[SipFields.cashFrom] ?? '').toString());
    if (stored != null) return SipMath.dayOf(stored);
    final created = DateTime.tryParse((row['created_at'] ?? '').toString());
    if (created != null) return SipMath.dayOf(created);
    return SipMath.dayOf(_now());
  }

  /// Post the debit for a live installment against the mandate's account.
  ///
  /// `cash_posted` is written in the same breath, so a repeated refresh can
  /// never debit twice — the guard the whole design leans on.
  Future<bool> _postDebit(Json row, Json entry, String account) async {
    final id = entry['id']?.toString();
    final amount = (entry[InstallmentFields.amount] as num?)?.toDouble() ?? 0;
    if (id == null || amount <= 0) return false;

    await _repo.insert('cash_moves', {
      'account': account,
      'amount': -amount, // a SIP debit is money out
      'date': entry[InstallmentFields.date],
      'note': '${row['name'] ?? 'SIP'} installment',
    });
    final posted = {
      InstallmentFields.cashPosted: true,
      InstallmentFields.account: account,
    };
    await _repo.update(SipFields.table, id, posted);
    entry.addAll(posted);
    return true;
  }

  /// Recompute units from the stored ledger and write them to the row.
  Future<void> _rewriteUnits(Json row) async {
    final ledger = await _readLedger();
    await _writeUnits(
      row,
      ledger
          .where((e) =>
              (e[InstallmentFields.parentId] ?? '').toString() ==
              row['id'].toString())
          .toList(),
    );
  }

  /// Write the derived figures onto the investment row.
  ///
  /// `quantity` is the contract with [InvestmentSync], which multiplies it by
  /// the latest NAV. `current_value` is deliberately absent — writing it here
  /// would make two writers for one figure.
  Future<void> _writeUnits(Json row, List<Json> installments) async {
    final parsed = [for (final e in installments) installmentFrom(e)];
    final units = SipMath.totalUnits(parsed);
    final invested = SipMath.totalInvested(parsed);

    final sameUnits =
        ((row[InvestmentFields.quantity] as num?)?.toDouble() ?? -1) == units;
    final sameInvested =
        ((row['total_invested'] as num?)?.toDouble() ?? -1) == invested;
    if (sameUnits && sameInvested) return;

    final values = {
      InvestmentFields.quantity: units,
      'total_invested': invested,
      // The symbol InvestmentSync prices this row with. Set here so a SIP row
      // is live the moment it is created, without the user typing a code twice.
      InvestmentFields.symbol: schemeCodeOf(row).toString(),
    };
    await _repo.update(investmentsTable, row['id'].toString(), values);
    row.addAll(values);
  }

  Future<List<Json>> _readLedger() async {
    try {
      return await _repo.list(SipFields.table);
    } catch (_) {
      // A project that has not created the table yet still gets a working
      // Investment screen; it simply has no ledger to read.
      return [];
    }
  }

  /// Storage row → the math layer's view of an installment.
  static Installment installmentFrom(Json e) => Installment(
        date: DateTime.tryParse((e[InstallmentFields.date] ?? '').toString()) ??
            DateTime(1970),
        amount: (e[InstallmentFields.amount] as num?)?.toDouble() ?? 0,
        nav: (e[InstallmentFields.nav] as num?)?.toDouble(),
        navDate: DateTime.tryParse(
            (e[InstallmentFields.navDate] ?? '').toString()),
        skipped: e[InstallmentFields.skipped] == true,
        // Only an explicit override counts: the stored `units` is normally just
        // amount ÷ nav written out, and treating it as an override would freeze
        // a figure that should follow a corrected NAV.
        unitsOverride: e['units_override'] == true
            ? (e[InstallmentFields.units] as num?)?.toDouble()
            : null,
      );

  /// The installments a schedule implies, without persisting anything.
  ///
  /// Identical arithmetic to what [_reconcile] would have written: every due
  /// date from the start through today, allotted at the NAV in force. Used
  /// when the ledger cannot be stored, so a holding is still valued correctly
  /// from what it was set up with.
  static List<Json> derive(Json row, NavSeries series, {DateTime? now}) {
    final start =
        DateTime.tryParse((row[SipFields.startDate] ?? '').toString());
    final amount = (row[SipFields.amount] as num?)?.toDouble() ?? 0;
    if (start == null || amount <= 0 || row[SipFields.active] == false) {
      return const [];
    }

    final dates = SipMath.generateSchedule(
      start: start,
      frequency: sipFrequencyFrom(row[SipFields.frequency]),
      day: (row[SipFields.day] as num?)?.toInt() ?? start.day,
      through: SipMath.dayOf(now ?? DateTime.now()),
      notBefore: series.earliest,
    );

    return [
      for (final date in dates)
        () {
          final due = amountOn(row, date);
          return {
            InstallmentFields.parentId: row['id'].toString(),
            InstallmentFields.date: isoDay(date),
            InstallmentFields.amount: due,
            InstallmentFields.source: 'derived',
            ..._allotmentFor(date, due, series),
          };
        }()
    ];
  }

  /// The static half of [_allotment], usable without an instance.
  static Json _allotmentFor(DateTime date, double amount, NavSeries series) {
    final navDate = SipMath.resolveAllotmentDate(date, series);
    if (navDate == null) return {};
    final nav = series.navOn(navDate)!;
    return {
      InstallmentFields.nav: nav,
      InstallmentFields.navDate: isoDay(navDate),
      InstallmentFields.units: amount / nav,
    };
  }

  /// Turn a storage failure into something worth reading. The missing-table
  /// case is by far the most common and has an exact remedy, so it gets named
  /// rather than buried in a Postgrest exception string.
  static String _ledgerMessage(Object e) {
    if (e.toString().contains(SipFields.table)) {
      return 'history cannot be saved until the ${SipFields.table} table '
          'exists — run the migration to edit installments';
    }
    return 'installment history cannot be saved ($e)';
  }

  static String isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
