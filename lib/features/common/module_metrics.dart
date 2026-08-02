import 'package:intl/intl.dart';

import '../../core/formatters.dart';
import '../../data/finance_repository.dart';
import '../../data/module_event.dart';
import '../../models/dashboard_spec.dart';

/// Per-module dashboard computation.
///
/// Pure Dart — no Flutter imports, no I/O — following the discipline of
/// `features/dashboard/analytics.dart` and `trends.dart`, so every rule below
/// is unit-testable.
///
/// The date arguments throughout are **inclusive** on both ends, because they
/// arrive from `_activeRange()` in `entity_screen.dart`, which speaks in
/// inclusive `DateTimeRange`s. Internally, comparisons are made against
/// end-of-day instants so a row dated on the last day falls inside the range.

/// One headline figure, already formatted for display.
class Stat {
  const Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  String toString() => 'Stat($label, $value)';
}

/// One column or vertex of a chart.
class SeriesPoint {
  const SeriesPoint(this.label, this.value);

  final String label;
  final double value;
}

/// A chartable series. [second] is populated only for dual-line charts.
class Series {
  const Series({
    required this.kind,
    required this.label,
    required this.points,
    this.second,
    this.firstLabel,
    this.secondLabel,
  });

  final ChartKind kind;
  final String label;
  final List<SeriesPoint> points;
  final List<SeriesPoint>? second;
  final String? firstLabel;
  final String? secondLabel;

  bool get isEmpty => points.isEmpty;

  /// True when nothing was ever non-zero. Drawn as an empty state rather than
  /// a flat line on the axis, which would read as a measurement.
  bool get isFlatZero =>
      points.every((p) => p.value == 0) &&
      (second ?? const <SeriesPoint>[]).every((p) => p.value == 0);
}

/// One column of a chart: a labelled span with inclusive [start] and [end].
class TimeBucket {
  const TimeBucket(this.label, this.start, this.end);

  final String label;
  final DateTime start;

  /// The last instant of the span, not the next span's start — so a value
  /// recorded on the final day lands in this bucket and not the next one.
  final DateTime end;
}

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _endOfDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

double _num(Json r, String key) => (r[key] as num?)?.toDouble() ?? 0;

DateTime? _rowDate(Json r) {
  final v = r['date'];
  if (v == null) return null;
  final d = DateTime.tryParse(v.toString());
  if (d == null) return null;
  return d.isUtc ? d.toLocal() : d;
}

/// Divide the inclusive span [start]–[end] into a readable number of columns.
///
/// Granularity follows the span rather than the selected period, so "All" over
/// three years and "Month" over 31 days both produce a chart you can read.
List<TimeBucket> buildTimeBuckets(DateTime start, DateTime end) {
  final from = _midnight(start);
  final to = _midnight(end);
  final days = to.difference(from).inDays + 1;

  if (days <= 1) {
    return [TimeBucket(DateFormat('d MMM').format(from), from, _endOfDay(from))];
  }

  if (days <= 16) {
    return [
      for (var i = 0; i < days; i++)
        _dayBucket(from.add(Duration(days: i))),
    ];
  }

  if (days <= 92) {
    final weeks = (days / 7).ceil();
    return [
      for (var i = 0; i < weeks; i++) _weekBucket(from, to, i),
    ];
  }

  // Monthly, inclusive of both endpoint months.
  final out = <TimeBucket>[];
  var cursor = DateTime(from.year, from.month, 1);
  final last = DateTime(to.year, to.month, 1);
  while (!cursor.isAfter(last)) {
    final next = DateTime(cursor.year, cursor.month + 1, 1);
    out.add(TimeBucket(
      DateFormat('MMM').format(cursor),
      cursor,
      _endOfDay(next.subtract(const Duration(days: 1))),
    ));
    cursor = next;
  }
  return out;
}

TimeBucket _dayBucket(DateTime d) =>
    TimeBucket(DateFormat('d/M').format(d), d, _endOfDay(d));

TimeBucket _weekBucket(DateTime from, DateTime to, int index) {
  final start = from.add(Duration(days: index * 7));
  final raw = start.add(const Duration(days: 6));
  return TimeBucket(
    DateFormat('d/M').format(start),
    start,
    _endOfDay(raw.isAfter(to) ? to : raw),
  );
}

// ------------------------------------------------------------------ stats

List<Stat> statsFor({
  required DashboardSpec spec,
  required List<Json> rows,
  required List<Json> events,
  required String parentType,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) =>
    [
      for (final s in spec.stats)
        _stat(s, rows, events, parentType, rangeStart, rangeEnd),
    ];

Stat _stat(
  StatSpec s,
  List<Json> rows,
  List<Json> events,
  String parentType,
  DateTime? from,
  DateTime? to,
) {
  double sum(String key) => rows.fold(0.0, (a, r) => a + _num(r, key));

  switch (s.kind) {
    case StatKind.sum:
      return Stat(s.label, money(sum(s.field!)));

    case StatKind.outstanding:
      final total = rows
          .where((r) => r['status'] != 'settled')
          .fold(0.0, (a, r) => a + _num(r, s.field!));
      return Stat(s.label, money(total));

    case StatKind.progress:
      final target = sum(s.against!);
      if (target <= 0) return Stat(s.label, '—');
      final pct = (sum(s.field!) / target * 100).clamp(0.0, 100.0);
      return Stat(s.label, '${_pct(pct)}%');

    case StatKind.ratio:
      final base = sum(s.against!);
      if (base <= 0) return Stat(s.label, '—');
      final pct = (sum(s.field!) - base) / base * 100;
      return Stat(s.label, '${pct >= 0 ? '+' : '−'}${_pct(pct.abs())}%');

    case StatKind.eventSum:
      final kinds = s.eventKinds!.map((k) => k.name).toSet();
      var total = 0.0;
      for (final e in events) {
        if (Events.parentType(e) != parentType) continue;
        if (Events.field(e) != s.field) continue;
        if (!kinds.contains(Events.kind(e))) continue;
        final d = Events.date(e);
        if (d == null) continue;
        if (from != null && d.isBefore(_midnight(from))) continue;
        if (to != null && d.isAfter(_endOfDay(to))) continue;
        total += Events.amount(e);
      }
      return Stat(s.label, money(total));

    case StatKind.count:
      return Stat(s.label, '${rows.length}');
  }
}

/// One decimal place, with a redundant `.0` dropped: 51.7, 100, 13.
/// Matches `_pct` in `features/dashboard/trends.dart`.
String _pct(double v) {
  final rounded = (v * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
}

// ----------------------------------------------------------------- series

Series? seriesFor({
  required DashboardSpec spec,
  required List<Json> rows,
  required List<Json> events,
  required String parentType,
  required DateTime now,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) {
  final chart = spec.chart;
  if (chart == null) return null;

  final span = _span(
    chart: chart,
    rows: rows,
    events: events,
    parentType: parentType,
    now: now,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
  );
  if (span == null) return null;

  final buckets = buildTimeBuckets(span.$1, span.$2);

  switch (chart.kind) {
    case ChartKind.cumulative:
      return Series(
        kind: chart.kind,
        label: chart.label,
        points: _cumulative(events, parentType, chart.field, buckets),
      );

    case ChartKind.dualCumulative:
      return Series(
        kind: chart.kind,
        label: chart.label,
        points: _cumulative(events, parentType, chart.field, buckets),
        second: _cumulative(events, parentType, chart.second!, buckets),
        firstLabel: chart.firstLabel,
        secondLabel: chart.secondLabel,
      );

    case ChartKind.bars:
      return Series(
        kind: chart.kind,
        label: chart.label,
        points: _bars(rows, chart.field, buckets),
      );
  }
}

/// The inclusive span the chart should cover, or null when there is nothing to
/// draw — no ledger for a cumulative chart, no dated rows for a bar chart.
(DateTime, DateTime)? _span({
  required ChartSpec chart,
  required List<Json> rows,
  required List<Json> events,
  required String parentType,
  required DateTime now,
  DateTime? rangeStart,
  DateTime? rangeEnd,
}) {
  if (chart.kind == ChartKind.bars) {
    final dates = rows.map(_rowDate).whereType<DateTime>().toList()..sort();
    if (dates.isEmpty) return null;
    if (rangeStart != null && rangeEnd != null) return (rangeStart, rangeEnd);
    return (dates.first, dates.last.isAfter(now) ? dates.last : now);
  }

  final first = Events.forField(events, parentType, chart.field);
  final second = chart.second == null
      ? const <Json>[]
      : Events.forField(events, parentType, chart.second!);
  if (first.isEmpty && second.isEmpty) return null;

  if (rangeStart != null && rangeEnd != null) return (rangeStart, rangeEnd);

  // "All": span from the earliest recorded event to today.
  final earliest = [
    if (first.isNotEmpty) Events.date(first.first)!,
    if (second.isNotEmpty) Events.date(second.first)!,
  ].reduce((a, b) => a.isBefore(b) ? a : b);
  return (earliest, now);
}

/// Combined balance across every parent row at the close of each bucket.
///
/// Reads the recorded `balance_after` rather than re-deriving forward from an
/// opening figure, so a `set` event bends the curve and hand-edited rows can't
/// make the chart disagree with the total printed above it. A balance
/// established before the window carries into its first bucket, and a bucket
/// with no events holds the previous balance rather than dropping to zero.
List<SeriesPoint> _cumulative(
  List<Json> events,
  String parentType,
  String field,
  List<TimeBucket> buckets,
) {
  final evs = Events.forField(events, parentType, field);
  final latest = <String, double>{};
  var i = 0;
  final out = <SeriesPoint>[];

  for (final b in buckets) {
    while (i < evs.length && !Events.date(evs[i])!.isAfter(b.end)) {
      latest[Events.parentId(evs[i])] = Events.balanceAfter(evs[i]);
      i++;
    }
    out.add(SeriesPoint(b.label, latest.values.fold(0.0, (a, v) => a + v)));
  }
  return out;
}

/// Sum of a dated column per bucket — for modules whose rows carry a `date`.
List<SeriesPoint> _bars(
  List<Json> rows,
  String field,
  List<TimeBucket> buckets,
) {
  final totals = List<double>.filled(buckets.length, 0);
  for (final r in rows) {
    final d = _rowDate(r);
    if (d == null) continue;
    for (var i = 0; i < buckets.length; i++) {
      if (!d.isBefore(buckets[i].start) && !d.isAfter(buckets[i].end)) {
        totals[i] += _num(r, field);
        break;
      }
    }
  }
  return [
    for (var i = 0; i < buckets.length; i++)
      SeriesPoint(buckets[i].label, totals[i]),
  ];
}
