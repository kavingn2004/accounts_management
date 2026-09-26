import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/features/dashboard/analytics.dart';
import 'package:accounts_app/features/dashboard/trends.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fixed "now" so every window assertion is a plain date comparison rather
/// than arithmetic against the wall clock.
final _now = DateTime(2026, 7, 30, 15, 0);

Json _row(double amount, String date) => {'amount': amount, 'date': date};

Json _debt(String id, double amount,
        {String status = 'open', String? createdAt}) =>
    {
      'id': id,
      'amount': amount,
      'status': status,
      if (createdAt != null) 'created_at': createdAt,
    };

Json _payment(String parentId, double amount, String date) =>
    {'parent_id': parentId, 'amount': amount, 'date': date};

void main() {
  group('period windows', () {
    test('month spans the calendar month and the one before it', () {
      expect(currentWindow(Period.month, _now).start, DateTime(2026, 7, 1));
      expect(currentWindow(Period.month, _now).end, DateTime(2026, 8, 1));
      expect(previousWindow(Period.month, _now).start, DateTime(2026, 6, 1));
      expect(previousWindow(Period.month, _now).end, DateTime(2026, 7, 1));
    });

    test('month rolls back across the year boundary', () {
      final jan = DateTime(2026, 1, 12);
      expect(previousWindow(Period.month, jan).start, DateTime(2025, 12, 1));
      expect(previousWindow(Period.month, jan).end, DateTime(2026, 1, 1));
    });

    test('week is the trailing 7 days and the 7 before that', () {
      expect(currentWindow(Period.week, _now).start, DateTime(2026, 7, 24));
      expect(currentWindow(Period.week, _now).end, DateTime(2026, 7, 31));
      expect(previousWindow(Period.week, _now).start, DateTime(2026, 7, 17));
      expect(previousWindow(Period.week, _now).end, DateTime(2026, 7, 24));
    });

    test('today compares against yesterday', () {
      expect(currentWindow(Period.today, _now).start, DateTime(2026, 7, 30));
      expect(currentWindow(Period.today, _now).end, DateTime(2026, 7, 31));
      expect(previousWindow(Period.today, _now).start, DateTime(2026, 7, 29));
      expect(previousWindow(Period.today, _now).end, DateTime(2026, 7, 30));
    });

    test('year compares against the previous calendar year', () {
      expect(currentWindow(Period.year, _now).start, DateTime(2026, 1, 1));
      expect(currentWindow(Period.year, _now).end, DateTime(2027, 1, 1));
      expect(previousWindow(Period.year, _now).start, DateTime(2025, 1, 1));
      expect(previousWindow(Period.year, _now).end, DateTime(2026, 1, 1));
    });

    test('windows are half-open — the end date belongs to the next window', () {
      final w = currentWindow(Period.month, _now);
      expect(w.contains(DateTime(2026, 7, 1)), isTrue);
      expect(w.contains(DateTime(2026, 7, 31)), isTrue);
      expect(w.contains(DateTime(2026, 8, 1)), isFalse);
      expect(w.contains(DateTime(2026, 6, 30)), isFalse);
    });
  });

  group('flow trends (income, expenses)', () {
    test('a rise in income is good and reads as an increase', () {
      final rows = [
        _row(1000, '2026-06-10'), // previous month
        _row(1200, '2026-07-10'), // current month
      ];
      final t = flowTrend(Period.month, rows, goodWhenUp: true, now: _now)!;
      expect(t.label, '↑ 20% vs Jun');
      expect(t.mood, TrendMood.good);
    });

    test('a rise in expenses is the same arrow but a bad mood', () {
      final rows = [_row(1000, '2026-06-10'), _row(1200, '2026-07-10')];
      final t = flowTrend(Period.month, rows, goodWhenUp: false, now: _now)!;
      expect(t.label, '↑ 20% vs Jun');
      expect(t.mood, TrendMood.bad);
    });

    test('a fall in expenses is good', () {
      final rows = [_row(1000, '2026-06-10'), _row(750, '2026-07-10')];
      final t = flowTrend(Period.month, rows, goodWhenUp: false, now: _now)!;
      expect(t.label, '↓ 25% vs Jun');
      expect(t.mood, TrendMood.good);
    });

    test('percentages keep one decimal and drop a trailing zero', () {
      final rows = [_row(1000, '2026-06-10'), _row(1124, '2026-07-10')];
      expect(flowTrend(Period.month, rows, goodWhenUp: true, now: _now)!.label,
          '↑ 12.4% vs Jun');
    });

    test('rows outside both windows are ignored', () {
      final rows = [
        _row(9999, '2026-04-10'), // two months back
        _row(1000, '2026-06-10'),
        _row(1500, '2026-07-10'),
      ];
      expect(flowTrend(Period.month, rows, goodWhenUp: true, now: _now)!.label,
          '↑ 50% vs Jun');
    });

    test('rows with an unparseable or missing date are ignored, not zeroed',
        () {
      final rows = [
        _row(1000, '2026-06-10'),
        _row(1200, '2026-07-10'),
        {'amount': 500.0}, // no date at all
        _row(500, 'not-a-date'),
      ];
      expect(flowTrend(Period.month, rows, goodWhenUp: true, now: _now)!.label,
          '↑ 20% vs Jun');
    });

    test('week and today windows pick their own suffix', () {
      final week = [_row(100, '2026-07-20'), _row(150, '2026-07-27')];
      expect(flowTrend(Period.week, week, goodWhenUp: true, now: _now)!.label,
          '↑ 50% vs prev week');

      final today = [_row(100, '2026-07-29'), _row(50, '2026-07-30')];
      expect(flowTrend(Period.today, today, goodWhenUp: true, now: _now)!.label,
          '↓ 50% vs yesterday');
    });

    test('nothing in either window shows no indicator', () {
      expect(flowTrend(Period.month, const [], goodWhenUp: true, now: _now),
          isNull);
    });

    test('a zero baseline reads as new rather than an infinite percentage', () {
      final rows = [_row(1200, '2026-07-10')];
      final t = flowTrend(Period.month, rows, goodWhenUp: true, now: _now)!;
      expect(t.label, 'new');
      expect(t.mood, TrendMood.good);
    });

    test('an unchanged total says so instead of showing 0%', () {
      final rows = [_row(1000, '2026-06-10'), _row(1000, '2026-07-10')];
      final t = flowTrend(Period.month, rows, goodWhenUp: true, now: _now)!;
      expect(t.label, 'no change');
      expect(t.mood, TrendMood.neutral);
    });
  });

  group('outstanding reconstruction (debtors, creditors)', () {
    final monthStart = DateTime(2026, 7, 1);

    test('current outstanding excludes settled rows, matching the tile', () {
      final debts = [
        _debt('a', 5000),
        _debt('b', 12000, status: 'partial'),
        _debt('c', 3500, status: 'settled'),
      ];
      expect(outstandingNow(debts), 17000);
    });

    test('payments made during the period are added back to the baseline', () {
      final debts = [_debt('a', 4000, status: 'partial')];
      final payments = [
        _payment('a', 1000, '2026-07-12'), // inside the period
        _payment('a', 500, '2026-06-20'), // before it
      ];
      // At 1 Jul the debt still stood at 4000 + 1000 = 5000; the June payment
      // was already reflected in today's 4000.
      expect(outstandingAsOf(debts, payments, monthStart), 5000);
    });

    test('a payment dated on the period start counts as inside the period', () {
      final debts = [_debt('a', 4000, status: 'partial')];
      final payments = [_payment('a', 1000, '2026-07-01')];
      expect(outstandingAsOf(debts, payments, monthStart), 5000);
    });

    test('payments belonging to another row do not leak across', () {
      final debts = [_debt('a', 4000), _debt('b', 2000)];
      final payments = [_payment('b', 3000, '2026-07-12')];
      expect(outstandingAsOf(debts, payments, monthStart), 4000 + 5000);
    });

    test('a debt created inside the period did not exist at the baseline', () {
      final debts = [
        _debt('a', 5000, createdAt: '2026-06-15T10:00:00Z'),
        _debt('b', 50000, createdAt: '2026-07-14T10:00:00Z'),
      ];
      expect(outstandingAsOf(debts, const [], monthStart), 5000);
      expect(outstandingNow(debts), 55000);
    });

    test('rows with no created_at are treated as pre-existing, not new', () {
      // Legacy/on-device rows predating the timestamp. Assuming they are new
      // would invent a 100% spike on every one of them.
      final debts = [_debt('a', 5000)];
      expect(outstandingAsOf(debts, const [], monthStart), 5000);
    });

    test('a written-off debt invents no drop', () {
      // Settled with no account and no ledger entry: there is no record of
      // when it closed, so it contributes nothing at either instant.
      final debts = [_debt('a', 3500, status: 'settled')];
      expect(outstandingNow(debts), 0);
      expect(outstandingAsOf(debts, const [], monthStart), 0);
    });

    test('a partial row with no ledger reports no movement', () {
      // Paid down before debt_payments existed. Walking backwards from today's
      // truth yields the same figure at both instants — 0%, not a fabrication.
      final debts = [_debt('a', 12000, status: 'partial')];
      expect(outstandingAsOf(debts, const [], monthStart), 12000);
      expect(outstandingNow(debts), 12000);
    });

    test('a debt settled through an account shows the fall it really was', () {
      final debts = [_debt('a', 0, status: 'settled')];
      final payments = [_payment('a', 3500, '2026-07-20')];
      expect(outstandingNow(debts), 0);
      expect(outstandingAsOf(debts, payments, monthStart), 3500);
    });
  });

  group('stock trends', () {
    test('debtors falling is bad — less is owed to you', () {
      final debts = [_debt('a', 4000, status: 'partial')];
      final payments = [_payment('a', 1000, '2026-07-12')];
      final t = stockTrend(Period.month, debts, payments,
          goodWhenUp: true, now: _now)!;
      expect(t.label, '↓ 20% this month');
      expect(t.mood, TrendMood.bad);
    });

    test('creditors falling is good — you owe less', () {
      final debts = [_debt('a', 4000, status: 'partial')];
      final payments = [_payment('a', 1000, '2026-07-12')];
      final t = stockTrend(Period.month, debts, payments,
          goodWhenUp: false, now: _now)!;
      expect(t.label, '↓ 20% this month');
      expect(t.mood, TrendMood.good);
    });

    test('a constant base damps the percentage without changing direction', () {
      final debts = [_debt('a', 4000, status: 'partial')];
      final payments = [_payment('a', 1000, '2026-07-12')];
      // Bills are folded into the creditors figure but have no history, so
      // they sit on both sides of the comparison: 9000 -> 8000.
      final t = stockTrend(Period.month, debts, payments,
          goodWhenUp: false, now: _now, constantBase: 4000)!;
      expect(t.label, '↓ 11.1% this month');
      expect(t.mood, TrendMood.good);
    });

    test('an empty ledger and no debts shows no indicator', () {
      expect(
          stockTrend(Period.month, const [], const [],
              goodWhenUp: true, now: _now),
          isNull);
    });

    test('a first-ever debt reads as new', () {
      final debts = [_debt('a', 5000, createdAt: '2026-07-14T10:00:00Z')];
      final t = stockTrend(Period.month, debts, const [],
          goodWhenUp: true, now: _now)!;
      expect(t.label, 'new');
      expect(t.mood, TrendMood.good);
    });

    test('the span suffix follows the selected period', () {
      final debts = [_debt('a', 4000, status: 'partial')];
      final payments = [_payment('a', 1000, '2026-07-28')];
      expect(
          stockTrend(Period.week, debts, payments,
                  goodWhenUp: true, now: _now)!
              .label,
          '↓ 20% this week');
      expect(
          stockTrend(Period.year, debts, payments,
                  goodWhenUp: true, now: _now)!
              .label,
          '↓ 20% this year');
    });
  });

  group('investment return', () {
    test('a gain reads as a positive return', () {
      final t = returnTrend(85300, 75000)!;
      expect(t.label, '↑ 13.7% return');
      expect(t.mood, TrendMood.good);
    });

    test('a loss reads as a negative return', () {
      final t = returnTrend(67500, 75000)!;
      expect(t.label, '↓ 10% return');
      expect(t.mood, TrendMood.bad);
    });

    test('holding exactly what was put in is break-even', () {
      final t = returnTrend(75000, 75000)!;
      expect(t.label, 'break-even');
      expect(t.mood, TrendMood.neutral);
    });

    test('nothing invested yields no indicator rather than a division by zero',
        () {
      expect(returnTrend(0, 0), isNull);
      expect(returnTrend(5000, 0), isNull);
    });
  });

  group('savings progress', () {
    test('progress is measured against the total target', () {
      final t = progressTrend(192000, 640000)!;
      expect(t.label, '↑ 30% of target');
      expect(t.mood, TrendMood.good);
    });

    test('overshooting the target is held at the top of the level', () {
      expect(progressTrend(70000, 50000)!.label, '↑ 100% of target');
    });

    test('exactly meeting the target is a full level', () {
      expect(progressTrend(50000, 50000)!.label, '↑ 100% of target');
    });

    test('nothing saved yet is stated flatly, with no arrow', () {
      final t = progressTrend(0, 50000)!;
      expect(t.label, '0% of target');
      expect(t.mood, TrendMood.neutral);
    });

    test('no target set yields no indicator', () {
      expect(progressTrend(1000, 0), isNull);
    });
  });
}
