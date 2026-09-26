import '../../data/finance_repository.dart';
import '../../models/dashboard_spec.dart';
import '../common/module_metrics.dart';

/// Total balance across all accounts at the close of each time bucket.
///
/// Unlike every other module this needs no ledger. Account movements — income,
/// expenses, transfers and the signed `cash_moves` rows — are all dated
/// already, so the curve is a walk over data the app has always had.
///
/// Opening balances are treated as present from the first bucket, matching
/// [FinanceMath.balanceMap], which has no notion of when an account was
/// opened. Movements against an account that no longer exists are skipped, for
/// the same reason and by the same rule.
Series? accountBalanceSeries({
  required List<Json> accounts,
  required List<Json> income,
  required List<Json> expenses,
  required List<Json> transfers,
  required List<Json> cashMoves,
  required DateTime now,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) {
  if (accounts.isEmpty) return null;

  final names = {
    for (final a in accounts) (a['name'] ?? '').toString(),
  }..remove('');

  final opening = accounts.fold<double>(
      0, (a, r) => a + ((r['opening_balance'] as num?)?.toDouble() ?? 0));

  // (date, signed delta) for every movement touching a known account.
  final moves = <(DateTime, double)>[];

  void add(dynamic account, dynamic date, double delta) {
    final name = account?.toString();
    if (name == null || !names.contains(name)) return;
    final d = date == null ? null : DateTime.tryParse(date.toString());
    if (d == null) return;
    moves.add((d.isUtc ? d.toLocal() : d, delta));
  }

  double amt(Json r) => (r['amount'] as num?)?.toDouble() ?? 0;

  for (final r in income) {
    add(r['account'], r['date'], amt(r));
  }
  for (final r in expenses) {
    add(r['account'], r['date'], -amt(r));
  }
  for (final t in transfers) {
    add(t['from'], t['date'], -amt(t));
    add(t['to'], t['date'], amt(t));
  }
  for (final m in cashMoves) {
    // Already signed: negative is money out.
    add(m['account'], m['date'], amt(m));
  }

  moves.sort((a, b) => a.$1.compareTo(b.$1));

  final DateTime from;
  final DateTime to;
  if (rangeStart != null && rangeEnd != null) {
    from = rangeStart;
    to = rangeEnd;
  } else if (moves.isEmpty) {
    from = now;
    to = now;
  } else {
    from = moves.first.$1;
    to = moves.last.$1.isAfter(now) ? moves.last.$1 : now;
  }

  final buckets = buildTimeBuckets(from, to);
  var running = opening;
  var i = 0;
  final points = <SeriesPoint>[];

  // Movements before the window are folded into the opening figure, so the
  // first bucket shows the balance as it actually stood rather than as it
  // started.
  while (i < moves.length && moves[i].$1.isBefore(buckets.first.start)) {
    running += moves[i].$2;
    i++;
  }

  for (final b in buckets) {
    while (i < moves.length && !moves[i].$1.isAfter(b.end)) {
      running += moves[i].$2;
      i++;
    }
    points.add(SeriesPoint(b.label, running));
  }

  return Series(
    kind: ChartKind.cumulative,
    label: 'Balance',
    points: points,
  );
}
