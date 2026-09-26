import '../../data/finance_repository.dart';
import 'analytics.dart';

/// Period-over-period trend indicators for the dashboard metric tiles.
///
/// Pure computation over already-fetched rows, like [analytics.dart] — no I/O,
/// no Flutter imports, so every rule below is unit-testable.
///
/// The six tiles do not all mean the same thing, and this file does not pretend
/// they do:
///
///   * **Flows** (income, expenses) are sums over a window. The comparison is
///     window vs preceding window — "↑ 12.4% vs last month".
///   * **Stocks** (debtors, creditors) are balances, so they are compared as
///     two *instants*: now vs the start of the selected period — "↑ 5% this
///     month". The baseline is walked backwards from today's known total (see
///     [outstandingAsOf]).
///   * **Ratios** (investment, savings) have no stored history at all —
///     `current_value` and `saved_amount` are overwritten in place. They report
///     what the data actually supports: return on capital, and progress toward
///     target.

/// Whether a movement is favourable, which is what picks the tile's colour.
/// Direction alone will not do — rising expenses are an increase *and* bad.
enum TrendMood { good, bad, neutral }

/// A rendered indicator: the line shown under a tile's figure, plus its mood.
class Trend {
  const Trend(this.label, this.mood);

  final String label;
  final TrendMood mood;

  @override
  String toString() => 'Trend($label, $mood)';
}

/// A half-open date range: [start] is included, [end] is not. Half-open avoids
/// the classic double-count where a row on a boundary date lands in both the
/// current window and the previous one.
class DateWindow {
  const DateWindow(this.start, this.end);

  final DateTime start;
  final DateTime end;

  bool contains(DateTime d) => !d.isBefore(start) && d.isBefore(end);

  @override
  String toString() => 'DateWindow($start, $end)';
}

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

/// The window the selected period covers, relative to [now].
DateWindow currentWindow(Period p, DateTime now) {
  final today = _midnight(now);
  return switch (p) {
    Period.today => DateWindow(today, today.add(const Duration(days: 1))),
    Period.week => DateWindow(today.subtract(const Duration(days: 6)),
        today.add(const Duration(days: 1))),
    Period.month =>
      DateWindow(DateTime(now.year, now.month, 1), DateTime(now.year, now.month + 1, 1)),
    Period.year => DateWindow(DateTime(now.year, 1, 1), DateTime(now.year + 1, 1, 1)),
  };
}

/// The window immediately preceding [currentWindow] — the flow baseline.
DateWindow previousWindow(Period p, DateTime now) {
  final cur = currentWindow(p, now);
  return switch (p) {
    Period.today =>
      DateWindow(cur.start.subtract(const Duration(days: 1)), cur.start),
    Period.week =>
      DateWindow(cur.start.subtract(const Duration(days: 7)), cur.start),
    Period.month => DateWindow(DateTime(now.year, now.month - 1, 1), cur.start),
    Period.year => DateWindow(DateTime(now.year - 1, 1, 1), cur.start),
  };
}

/// Suffix for a flow, which compares two windows.
///
/// Names the period being compared against rather than saying "vs last month".
/// Shorter — the tile is half a phone wide and the delta line must not
/// ellipsize — and it states the baseline outright, which matters because a
/// month two days old is still measured against the whole of the one before.
String periodSuffix(Period p, DateTime now) {
  final prev = previousWindow(p, now).start;
  return switch (p) {
    Period.today => 'vs yesterday',
    Period.week => 'vs prev week',
    Period.month => 'vs ${_months[prev.month - 1]}',
    Period.year => 'vs ${prev.year}',
  };
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Suffix for a stock, which compares now against the start of the period.
/// Deliberately different wording from [periodSuffix]: a balance has not been
/// measured "against last month", it has moved *during* this one.
String spanSuffix(Period p) => switch (p) {
      Period.today => 'today',
      Period.week => 'this week',
      Period.month => 'this month',
      Period.year => 'this year',
    };

double _amount(Json r) => (r['amount'] as num?)?.toDouble() ?? 0;

/// Parse a `yyyy-MM-dd` or full ISO timestamp. Rows with a missing or
/// unparseable date are skipped by callers rather than counted as zero.
DateTime? _date(dynamic v) {
  if (v == null) return null;
  final d = DateTime.tryParse(v.toString());
  return d?.isUtc == true ? d!.toLocal() : d;
}

/// Total `amount` of every row dated inside [w].
double sumAmountIn(List<Json> rows, DateWindow w) {
  var total = 0.0;
  for (final r in rows) {
    final d = _date(r['date']);
    if (d != null && w.contains(d)) total += _amount(r);
  }
  return total;
}

/// Render a comparison, or null when there is nothing worth showing.
Trend? _compare(
  double current,
  double previous, {
  required bool goodWhenUp,
  required String suffix,
}) {
  if (current == 0 && previous == 0) return null;
  if (previous == 0) {
    return Trend('new', goodWhenUp ? TrendMood.good : TrendMood.bad);
  }
  if (current == previous) return const Trend('no change', TrendMood.neutral);

  final up = current > previous;
  final pct = (current - previous).abs() / previous.abs() * 100;
  return Trend(
    '${up ? '↑' : '↓'} ${_pct(pct)}% $suffix',
    up == goodWhenUp ? TrendMood.good : TrendMood.bad,
  );
}

/// One decimal place, with a redundant `.0` dropped: 12.4, 20, 11.1.
String _pct(double v) {
  final rounded = (v * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

/// Trend for a flow metric: this window's total against the preceding one.
Trend? flowTrend(
  Period p,
  List<Json> rows, {
  required bool goodWhenUp,
  required DateTime now,
}) =>
    _compare(
      sumAmountIn(rows, currentWindow(p, now)),
      sumAmountIn(rows, previousWindow(p, now)),
      goodWhenUp: goodWhenUp,
      suffix: periodSuffix(p, now),
    );

/// Outstanding total right now — settled rows excluded, matching the
/// `debt_worth` / `credit_worth` figures printed above the indicator.
double outstandingNow(List<Json> debts) => debts
    .where((r) => r['status'] != 'settled')
    .fold(0.0, (a, r) => a + _amount(r));

/// Outstanding total as it stood at [asOf], reconstructed by walking backwards
/// from today: whatever is still owed, plus every instalment repaid since.
///
/// Backwards, not forwards from `original_amount`, and the difference matters.
/// A forward rebuild is only correct when the `debt_payments` ledger is
/// complete — rows paid down before that table existed would be reported at
/// their original value and contradict the total shown on the tile. Walking
/// backwards is exact at `asOf = now` by construction, so the indicator can
/// never disagree with the figure above it.
///
/// Two things it deliberately will not guess:
///
///   * A debt written off (settled with no account, so no ledger entry) has no
///     closing timestamp. It counts as zero at every instant — no invented drop.
///   * A row paid down with no ledger entry reports no movement at all.
double outstandingAsOf(
  List<Json> debts,
  List<Json> payments,
  DateTime asOf,
) {
  // Instalments repaid on or after the baseline instant, by parent row. `asOf`
  // is always a midnight period start and payment dates are day-granular, so
  // `>=` is what puts a payment made on the 1st inside the month.
  final repaidSince = <String, double>{};
  for (final p in payments) {
    final d = _date(p['date']);
    if (d == null || d.isBefore(asOf)) continue;
    final key = (p['parent_id'] ?? '').toString();
    repaidSince[key] = (repaidSince[key] ?? 0) + _amount(p);
  }

  var total = 0.0;
  for (final r in debts) {
    // A row created after the baseline did not exist yet. Rows with no
    // `created_at` (on-device rows predating the stamp) are treated as
    // pre-existing — assuming otherwise would invent a spike on every one.
    final created = _date(r['created_at']);
    if (created != null && !created.isBefore(asOf)) continue;

    final remaining = r['status'] == 'settled' ? 0.0 : _amount(r);
    total += remaining + (repaidSince[r['id'].toString()] ?? 0);
  }
  return total;
}

/// Trend for a stock metric: today's outstanding against the period's start.
///
/// [constantBase] is added to both instants for figures that carry a component
/// with no history — the creditors tile folds in recurring bills, which are
/// templates rather than balances. Present on both sides, they damp the
/// percentage but cannot distort its direction.
Trend? stockTrend(
  Period p,
  List<Json> debts,
  List<Json> payments, {
  required bool goodWhenUp,
  required DateTime now,
  double constantBase = 0,
}) =>
    _compare(
      outstandingNow(debts) + constantBase,
      outstandingAsOf(debts, payments, currentWindow(p, now).start) +
          constantBase,
      goodWhenUp: goodWhenUp,
      suffix: spanSuffix(p),
    );

/// Return on capital: what the holdings are worth against what went in.
///
/// Not a period comparison — investments store no value history, so there is
/// no honest way to say what they were worth last month.
Trend? returnTrend(double currentValue, double invested) {
  if (invested <= 0) return null;
  final pct = (currentValue - invested) / invested * 100;
  if (pct == 0) return const Trend('break-even', TrendMood.neutral);
  final up = pct > 0;
  return Trend(
    '${up ? '↑' : '↓'} ${_pct(pct.abs())}% return',
    up ? TrendMood.good : TrendMood.bad,
  );
}

/// Progress toward the combined savings target, held inside the 0–100 level so
/// a full bar is a met goal. Overshoot reads as 100%, matching the per-goal
/// rows in the savings module (see `Modules.savings.trailingOf`).
Trend? progressTrend(double saved, double target) {
  if (target <= 0) return null;
  final pct = (saved / target * 100).clamp(0.0, 100.0);
  if (pct <= 0) return const Trend('0% of target', TrendMood.neutral);
  return Trend('↑ ${_pct(pct)}% of target', TrendMood.good);
}
