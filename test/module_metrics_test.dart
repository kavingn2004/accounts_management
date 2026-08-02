import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/features/common/module_metrics.dart';
import 'package:accounts_app/models/dashboard_spec.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fixed "now" so every assertion is a plain date comparison rather than
/// arithmetic against the wall clock — the convention in dashboard_trends_test.
final _now = DateTime(2026, 8, 2, 12);

Json _goal(String id, double saved, double target) =>
    {'id': id, 'saved_amount': saved, 'target_amount': target};

Json _ev(
  String id,
  String date,
  double after, {
  String field = 'saved_amount',
  String kind = 'increment',
  double amount = 0,
  String type = 'savings_goals',
}) =>
    {
      'parent_id': id,
      'parent_type': type,
      'field': field,
      'kind': kind,
      'amount': amount,
      'balance_after': after,
      'date': date,
    };

const _savingsSpec = DashboardSpec(
  stats: [
    StatSpec.sum('saved_amount', 'Saved'),
    StatSpec.sum('target_amount', 'Target'),
    StatSpec.progress('saved_amount', 'target_amount', 'Of target'),
    StatSpec.eventSum('saved_amount', 'Contributed'),
  ],
  chart: ChartSpec.cumulative('saved_amount', label: 'Savings growth'),
);

void main() {
  group('stats', () {
    test('sums and progress come from the rows, not the ledger', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 120000, 200000), _goal('b', 30000, 90000)],
        events: const [],
        parentType: 'savings_goals',
      );
      expect(stats[0].label, 'Saved');
      expect(stats[0].value, '₹1,50,000');
      expect(stats[1].value, '₹2,90,000');
      expect(stats[2].value, '51.7%');
    });

    test('progress clamps at 100% so an overshot goal reads as met', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 250000, 200000)],
        events: const [],
        parentType: 'savings_goals',
      );
      expect(stats[2].value, '100%');
    });

    test('progress against a zero target is dashed, not divided by zero', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 5000, 0)],
        events: const [],
        parentType: 'savings_goals',
      );
      expect(stats[2].value, '—');
    });

    test('eventSum counts only increments inside the inclusive range', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 110000, 200000)],
        events: [
          _ev('a', '2026-07-31', 105000, amount: 5000),
          _ev('a', '2026-08-01', 108000, amount: 3000),
          _ev('a', '2026-08-02', 110000, amount: 2000),
          _ev('a', '2026-08-01', 108000, amount: 999, kind: 'open'),
        ],
        parentType: 'savings_goals',
        rangeStart: DateTime(2026, 8, 1),
        rangeEnd: DateTime(2026, 8, 31),
      );
      expect(stats[3].value, '₹5,000');
    });

    test('a null range means all time', () {
      final stats = statsFor(
        spec: _savingsSpec,
        rows: [_goal('a', 110000, 200000)],
        events: [
          _ev('a', '2026-01-05', 5000, amount: 5000),
          _ev('a', '2026-08-02', 110000, amount: 2000),
        ],
        parentType: 'savings_goals',
      );
      expect(stats[3].value, '₹7,000');
    });

    test('ratio is a signed return on capital', () {
      const spec = DashboardSpec(stats: [
        StatSpec.ratio('current_value', 'total_invested', 'Return'),
      ]);
      final stats = statsFor(
        spec: spec,
        rows: [
          {'current_value': 85300.0, 'total_invested': 75000.0},
        ],
        events: const [],
        parentType: 'investments',
      );
      expect(stats.single.value, '+13.7%');
    });

    test('paidDown is exact from the rows, needing no ledger at all', () {
      const spec = DashboardSpec(stats: [
        StatSpec.paidDown('amount', 'original_amount', 'Received'),
      ]);
      final stats = statsFor(
        spec: spec,
        rows: [
          // Never paid against, and no original_amount column at all.
          {'amount': 5000.0, 'status': 'open'},
          // Part-paid: 20000 owed, 12000 left.
          {'amount': 12000.0, 'original_amount': 20000.0, 'status': 'partial'},
          // Settled through an account: the balance was zeroed.
          {'amount': 0.0, 'original_amount': 3500.0, 'status': 'settled'},
        ],
        events: const [],
        parentType: 'debtors',
      );
      expect(stats.single.value, '\u20b911,500');
    });

    test('a write-off counts as nothing received', () {
      const spec = DashboardSpec(stats: [
        StatSpec.paidDown('amount', 'original_amount', 'Received'),
      ]);
      // Settling with no account keeps the amount for history, so nothing
      // was actually collected — and nothing must be reported as collected.
      final stats = statsFor(
        spec: spec,
        rows: [
          {'amount': 4000.0, 'original_amount': 4000.0, 'status': 'settled'},
        ],
        events: const [],
        parentType: 'debtors',
      );
      expect(stats.single.value, '\u20b90');
    });

    test('paidDown never goes negative if a balance was raised', () {
      const spec = DashboardSpec(stats: [
        StatSpec.paidDown('outstanding', 'principal', 'Paid'),
      ]);
      final stats = statsFor(
        spec: spec,
        // Interest accrual can push outstanding above the original principal.
        rows: [
          {'outstanding': 90000.0, 'principal': 80000.0},
        ],
        events: const [],
        parentType: 'loans',
      );
      expect(stats.single.value, '\u20b90');
    });

    test('outstanding excludes settled rows', () {
      const spec = DashboardSpec(stats: [
        StatSpec.outstanding('amount', 'Outstanding'),
      ]);
      final stats = statsFor(
        spec: spec,
        rows: [
          {'amount': 5000.0, 'status': 'open'},
          {'amount': 12000.0, 'status': 'partial'},
          {'amount': 3500.0, 'status': 'settled'},
        ],
        events: const [],
        parentType: 'debtors',
      );
      expect(stats.single.value, '₹17,000');
    });
  });

  group('time buckets', () {
    test('a single day is one bucket', () {
      final b = buildTimeBuckets(DateTime(2026, 8, 2), DateTime(2026, 8, 2));
      expect(b.length, 1);
    });

    test('a fortnight buckets by day', () {
      final b = buildTimeBuckets(DateTime(2026, 7, 20), DateTime(2026, 8, 2));
      expect(b.length, 14);
      expect(b.first.start, DateTime(2026, 7, 20));
      expect(b.last.start, DateTime(2026, 8, 2));
    });

    test('a year buckets by month', () {
      final b = buildTimeBuckets(DateTime(2026, 1, 1), DateTime(2026, 12, 31));
      expect(b.length, 12);
      expect(b.first.label, 'Jan');
      expect(b.last.label, 'Dec');
    });

    test('bucket ends are the last instant of their span, not the next start',
        () {
      final b = buildTimeBuckets(DateTime(2026, 1, 1), DateTime(2026, 12, 31));
      expect(b.first.end.month, 1);
      expect(b.first.end.day, 31);
    });
  });

  group('cumulative series', () {
    Series build(List<Json> events, {DateTime? from, DateTime? to}) => seriesFor(
          spec: _savingsSpec,
          rows: [_goal('a', 0, 200000)],
          events: events,
          parentType: 'savings_goals',
          now: _now,
          rangeStart: from,
          rangeEnd: to,
        )!;

    test('carries the last known balance forward across empty buckets', () {
      final s = build([
        _ev('a', '2026-01-15', 10000, kind: 'open', amount: 10000),
        _ev('a', '2026-03-10', 25000, amount: 15000),
      ], from: DateTime(2026, 1, 1), to: DateTime(2026, 12, 31));
      expect(s.points.length, 12);
      expect(s.points[0].value, 10000);
      expect(s.points[1].value, 10000); // Feb — no event, balance holds
      expect(s.points[2].value, 25000);
      expect(s.points[11].value, 25000);
    });

    test('sums the latest balance of every goal, not every event', () {
      final s = build([
        _ev('a', '2026-01-15', 10000, kind: 'open', amount: 10000),
        _ev('b', '2026-01-20', 5000, kind: 'open', amount: 5000),
        _ev('a', '2026-02-01', 30000, amount: 20000),
      ], from: DateTime(2026, 1, 1), to: DateTime(2026, 12, 31));
      expect(s.points[0].value, 15000);
      expect(s.points[1].value, 35000);
    });

    test('a set event bends the curve down rather than accumulating', () {
      final s = seriesFor(
        spec: const DashboardSpec(
          stats: [],
          chart: ChartSpec.cumulative('current_value', label: 'Value'),
        ),
        rows: const [],
        events: [
          _ev('a', '2026-01-15', 50000,
              field: 'current_value', kind: 'open', type: 'investments'),
          _ev('a', '2026-02-15', 42000,
              field: 'current_value', kind: 'set', type: 'investments'),
        ],
        parentType: 'investments',
        now: _now,
        rangeStart: DateTime(2026, 1, 1),
        rangeEnd: DateTime(2026, 12, 31),
      )!;
      expect(s.points[0].value, 50000);
      expect(s.points[1].value, 42000);
    });

    test('another module\'s ledger does not leak into this one', () {
      // Savings has no events of its own here, so there is nothing to draw —
      // not a flat zero line built from the investments ledger.
      final s = seriesFor(
        spec: _savingsSpec,
        rows: [_goal('a', 0, 200000)],
        events: [
          _ev('a', '2026-01-15', 50000,
              field: 'current_value', kind: 'open', type: 'investments'),
        ],
        parentType: 'savings_goals',
        now: _now,
        rangeStart: DateTime(2026, 1, 1),
        rangeEnd: DateTime(2026, 12, 31),
      );
      expect(s, isNull);
    });

    test('an event on the first of the range is inside it', () {
      final s = build([
        _ev('a', '2026-08-01', 7000, kind: 'open', amount: 7000),
      ], from: DateTime(2026, 8, 1), to: DateTime(2026, 8, 31));
      expect(s.points.first.value, 7000);
    });

    test('balances established before the range carry into it', () {
      final s = build([
        _ev('a', '2025-11-02', 90000, kind: 'open', amount: 90000),
      ], from: DateTime(2026, 8, 1), to: DateTime(2026, 8, 31));
      expect(s.points.first.value, 90000);
    });

    test('an empty ledger yields no series at all', () {
      final s = seriesFor(
        spec: _savingsSpec,
        rows: [_goal('a', 120000, 200000)],
        events: const [],
        parentType: 'savings_goals',
        now: _now,
      );
      expect(s, isNull);
    });
  });

  group('bar series', () {
    test('sums dated rows per bucket', () {
      const spec = DashboardSpec(
        stats: [],
        chart: ChartSpec.bars('amount', label: 'Spending'),
      );
      final s = seriesFor(
        spec: spec,
        rows: [
          {'amount': 1000.0, 'date': '2026-01-10'},
          {'amount': 500.0, 'date': '2026-01-20'},
          {'amount': 2000.0, 'date': '2026-03-01'},
        ],
        events: const [],
        parentType: 'expenses',
        now: _now,
        rangeStart: DateTime(2026, 1, 1),
        rangeEnd: DateTime(2026, 12, 31),
      )!;
      expect(s.points[0].value, 1500);
      expect(s.points[1].value, 0);
      expect(s.points[2].value, 2000);
    });
  });
}
