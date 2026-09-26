import '../../data/finance_repository.dart';
import '../../data/module_event.dart';
import 'quote_service.dart';

/// The row keys live tracking reads and writes. Named once here so the
/// registry, the screen and the sync can never disagree about a spelling.
class InvestmentFields {
  const InvestmentFields._();

  /// What to price: ticker, AMFI scheme code, CoinGecko id, or `gold`.
  static const symbol = 'symbol';

  /// How much is held: shares, units, coins, grams.
  static const quantity = 'quantity';

  /// A price per unit typed in by hand, in INR. Set it and the row stops
  /// asking the network entirely.
  ///
  /// For anything the app cannot or should not fetch: an unlisted holding, a
  /// gold rate from your own jeweller rather than international spot, or simply
  /// a figure you would rather control. It takes precedence over [symbol] on
  /// purpose — an explicit instruction outranks an inferred one. Clear it and
  /// the row goes back to live pricing.
  static const marketPrice = 'market_price';

  /// Written by the sync, read by the UI.
  static const lastPrice = 'last_price';
  static const priceAt = 'price_at';
  static const priceSource = 'price_source';

  static const value = 'current_value';
  static const type = 'type';
}

/// One row that was successfully priced. Carried in full rather than
/// pre-formatted so the UI decides how to word it.
class PricedRow {
  const PricedRow({
    required this.name,
    required this.price,
    required this.quantity,
    required this.value,
    required this.source,
  });

  final String name;
  final double price;
  final double quantity;
  final double value;
  final String source;
}

/// What one refresh did, in terms a person can be told.
class SyncOutcome {
  const SyncOutcome({
    this.checked = 0,
    this.updated = 0,
    this.priced = const [],
    this.failures = const {},
    this.platformBlocked = false,
  });

  /// Rows that got a price this round, whether or not it had moved.
  final List<PricedRow> priced;

  /// Rows that carry enough information to be priced.
  final int checked;

  /// Rows whose stored value actually moved.
  final int updated;

  /// Row name → why it could not be priced.
  final Map<String, String> failures;

  /// At least one failure was a browser refusing a call that no retry will fix,
  /// so the UI can point at the mobile app instead of the network.
  final bool platformBlocked;

  /// Nothing to do: no row on this screen has a symbol and a quantity.
  bool get isIdle => checked == 0;
}

/// Turns quotes into stored values.
///
/// This is the only place that writes a live price into a row, and it is
/// deliberately conservative: a row without both a symbol and a quantity is
/// never touched, and a failed lookup leaves the last known figure standing.
/// Live tracking must not be able to blank someone's portfolio.
class InvestmentSync {
  InvestmentSync({
    required FinanceRepository repo,
    required QuoteService quotes,
    this.table = 'investments',
    DateTime Function()? clock,
  })  : _repo = repo,
        _quotes = quotes,
        _now = clock ?? DateTime.now;

  final FinanceRepository _repo;
  final QuoteService _quotes;
  final String table;
  final DateTime Function() _now;

  /// Rounded the way money is stored, so float noise can't pass for a change.
  static double _round(double v) => (v * 100).roundToDouble() / 100;

  static double? _positive(Object? v) {
    final n = v is num ? v.toDouble() : double.tryParse((v ?? '').toString());
    return (n == null || n <= 0) ? null : n;
  }

  static String _symbolOf(Json row) =>
      (row[InvestmentFields.symbol] ?? '').toString().trim();

  /// Whether this row participates in live tracking at all.
  static bool isLive(Json row) =>
      _positive(row[InvestmentFields.quantity]) != null &&
      (_symbolOf(row).isNotEmpty ||
          _positive(row[InvestmentFields.marketPrice]) != null);

  /// Price every eligible row and write the ones that moved.
  ///
  /// [events] is the module ledger as already loaded by the caller; it is read
  /// only to avoid logging a second point for a row on a day that already has
  /// one. The ledger stores dates to the day, so more than one would be
  /// redundant — and left unchecked, a screen opened all afternoon would bury
  /// the chart's real revaluations under noise.
  Future<SyncOutcome> run(
    List<Json> rows, {
    List<Json> events = const [],
    bool force = false,
  }) async {
    final live = rows.where(isLive).toList();
    if (live.isEmpty) return const SyncOutcome();

    // Rows carrying a typed price are valued without a network call.
    final needQuote = live
        .where((r) => _positive(r[InvestmentFields.marketPrice]) == null)
        .toList();

    final batch = needQuote.isEmpty
        ? const QuoteBatch({}, {})
        : await _quotes.fetch(
            [
              for (final r in needQuote)
                QuoteRequest(
                    _symbolOf(r), (r[InvestmentFields.type] ?? '').toString())
            ],
            force: force,
          );

    final failures = <String, String>{};
    final priced = <PricedRow>[];
    var platformBlocked = false;
    var updated = 0;

    final today = _dayOf(_now());
    final loggedToday = _rowsLoggedOn(events, today);

    for (final row in live) {
      final name = (row['name'] ?? 'Investment').toString();
      final quantity = _positive(row[InvestmentFields.quantity])!;
      final manualRate = _positive(row[InvestmentFields.marketPrice]);

      double price;
      DateTime asOf;
      String source;

      if (manualRate != null) {
        price = manualRate;
        asOf = _now();
        source = 'Manual price';
      } else {
        final key = QuoteRequest(
                _symbolOf(row), (row[InvestmentFields.type] ?? '').toString())
            .key;
        final quote = batch.quotes[key];
        if (quote == null) {
          final failure = batch.failures[key];
          failures[name] = failure?.message ?? 'no price available';
          platformBlocked |= failure?.unsupportedOnPlatform ?? false;
          continue;
        }
        price = quote.price;
        asOf = quote.asOf;
        source = quote.source;
      }

      final value = _round(price * quantity);
      priced.add(PricedRow(
        name: name,
        price: price,
        quantity: quantity,
        value: value,
        source: source,
      ));
      final storedValue = (row[InvestmentFields.value] as num?)?.toDouble();
      final storedPrice =
          (row[InvestmentFields.lastPrice] as num?)?.toDouble();
      final storedAt = (row[InvestmentFields.priceAt] ?? '').toString();
      final atIso = asOf.toIso8601String();

      // Nothing moved — a fund whose NAV is still Friday's, most of the time.
      // Skipping the write keeps `price_at` meaning "when this price was set"
      // rather than "when we last asked".
      if (storedValue == value && storedPrice == price && storedAt == atIso) {
        continue;
      }

      await _repo.update(table, row['id'].toString(), {
        InvestmentFields.value: value,
        InvestmentFields.lastPrice: price,
        InvestmentFields.priceAt: atIso,
        InvestmentFields.priceSource: source,
      });
      // Keep the caller's in-memory copy honest, so the list can repaint from
      // the rows it already holds instead of waiting on a re-read.
      row[InvestmentFields.value] = value;
      row[InvestmentFields.lastPrice] = price;
      row[InvestmentFields.priceAt] = atIso;
      row[InvestmentFields.priceSource] = source;
      updated++;

      final valueMoved = storedValue == null || (storedValue - value).abs() >= 0.01;
      if (valueMoved && !loggedToday.contains(row['id'].toString())) {
        await logModuleEvent(
          _repo,
          ModuleEvent(
            parentId: row['id'].toString(),
            parentType: table,
            field: InvestmentFields.value,
            // A revaluation replaces rather than adjusts, exactly as the
            // manual "Update current value" action does.
            kind: EventKind.set,
            amount: value,
            balanceAfter: value,
            date: _now(),
            note: source,
          ),
        );
        loggedToday.add(row['id'].toString());
      }
    }

    return SyncOutcome(
      checked: live.length,
      updated: updated,
      priced: priced,
      failures: failures,
      platformBlocked: platformBlocked,
    );
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Ids that already have a value event dated [day].
  Set<String> _rowsLoggedOn(List<Json> events, DateTime day) {
    return {
      for (final e in Events.forField(events, table, InvestmentFields.value))
        if (Events.date(e) != null && _dayOf(Events.date(e)!) == day)
          Events.parentId(e),
    };
  }
}
