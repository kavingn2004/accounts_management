import 'package:intl/intl.dart';

import '../../data/finance_repository.dart';

enum Period { today, week, month, year }

extension PeriodLabel on Period {
  String get label => switch (this) {
        Period.today => 'Today',
        Period.week => 'Week',
        Period.month => 'Month',
        Period.year => 'Year',
      };
}

/// One bar group on the income-vs-expense chart.
class Bucket {
  Bucket(this.label, [this.income = 0, this.expense = 0]);
  final String label;
  double income;
  double expense;
}

/// One slice of the expense pie chart.
class PieSlice {
  PieSlice(this.label, this.value);
  final String label;
  final double value;
}

DateTime? _parseDate(dynamic v) =>
    v == null ? null : DateTime.tryParse(v.toString());

double _amount(Json r) => (r['amount'] as num?)?.toDouble() ?? 0;

/// Inclusive start of the selected period (relative to now).
DateTime _periodStart(Period p, DateTime now) => switch (p) {
      Period.today => DateTime(now.year, now.month, now.day),
      Period.week => DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 6)),
      Period.month => DateTime(now.year, now.month, 1),
      Period.year => DateTime(now.year, 1, 1),
    };

bool _inPeriod(DateTime d, Period p, DateTime now) =>
    !d.isBefore(_periodStart(p, now)) &&
    !d.isAfter(DateTime(now.year, now.month, now.day, 23, 59, 59));

/// Build the time buckets (7 days / weeks of month / 12 months) and fill them
/// with income + expense totals.
List<Bucket> buildBuckets(Period p, List<Json> income, List<Json> expenses) {
  final now = DateTime.now();
  final List<Bucket> buckets;
  int Function(DateTime) indexOf;

  switch (p) {
    case Period.today:
      buckets = [Bucket('Today')];
      indexOf = (_) => 0;
      break;
    case Period.week:
      buckets = List.generate(7, (i) {
        final day = now.subtract(Duration(days: 6 - i));
        return Bucket(DateFormat('E').format(day)); // Mon, Tue...
      });
      indexOf = (d) => 6 - now.difference(d).inDays;
      break;
    case Period.month:
      buckets = [Bucket('W1'), Bucket('W2'), Bucket('W3'), Bucket('W4')];
      indexOf = (d) => ((d.day - 1) ~/ 7).clamp(0, 3);
      break;
    case Period.year:
      buckets = List.generate(
          12, (i) => Bucket(DateFormat('MMM').format(DateTime(now.year, i + 1))));
      indexOf = (d) => d.month - 1;
      break;
  }

  void apply(List<Json> rows, bool isIncome) {
    for (final r in rows) {
      final d = _parseDate(r['date']);
      if (d == null || !_inPeriod(d, p, now)) continue;
      final i = indexOf(d);
      if (i < 0 || i >= buckets.length) continue;
      if (isIncome) {
        buckets[i].income += _amount(r);
      } else {
        buckets[i].expense += _amount(r);
      }
    }
  }

  apply(income, true);
  apply(expenses, false);
  return buckets;
}

/// Expense totals grouped by payee within the period (top 5 + "Other").
List<PieSlice> buildExpensePie(Period p, List<Json> expenses) {
  final now = DateTime.now();
  final totals = <String, double>{};
  for (final r in expenses) {
    final d = _parseDate(r['date']);
    if (d == null || !_inPeriod(d, p, now)) continue;
    final key = (r['payee'] ?? 'Other').toString();
    totals[key] = (totals[key] ?? 0) + _amount(r);
  }
  final entries = totals.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  if (entries.length <= 6) {
    return entries.map((e) => PieSlice(e.key, e.value)).toList();
  }
  final top = entries.take(5).map((e) => PieSlice(e.key, e.value)).toList();
  final other = entries.skip(5).fold(0.0, (a, e) => a + e.value);
  return [...top, PieSlice('Other', other)];
}
