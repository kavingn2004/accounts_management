import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/data/sip_math.dart';
import 'package:flutter_test/flutter_test.dart';

/// A NAV series with a published value on every weekday of the given span and
/// nothing at weekends — the shape the resolution rules exist to handle.
NavSeries _weekdaySeries(
  DateTime from,
  DateTime to, {
  double start = 100,
  double dailyGrowth = 0,
}) {
  final navs = <DateTime, double>{};
  var cursor = from;
  var nav = start;
  while (!cursor.isAfter(to)) {
    if (cursor.weekday <= DateTime.friday) navs[cursor] = nav;
    nav += dailyGrowth;
    cursor = cursor.add(const Duration(days: 1));
  }
  return NavSeries(
      code: 1, schemeName: 'Test Fund', fundHouse: 'Test AMC', navs: navs);
}

NavSeries _series(Map<DateTime, double> navs) =>
    NavSeries(code: 1, schemeName: 'F', fundHouse: 'H', navs: navs);

void main() {
  group('schedule generation', () {
    test('monthly lands on the chosen day, from start through today', () {
      final dates = SipMath.generateSchedule(
        start: DateTime(2026, 1, 5),
        frequency: SipFrequency.monthly,
        day: 5,
        through: DateTime(2026, 4, 20),
      );
      expect(dates, [
        DateTime(2026, 1, 5),
        DateTime(2026, 2, 5),
        DateTime(2026, 3, 5),
        DateTime(2026, 4, 5),
      ]);
    });

    test('day 31 clamps to the last day of shorter months', () {
      final dates = SipMath.generateSchedule(
        start: DateTime(2026, 1, 31),
        frequency: SipFrequency.monthly,
        day: 31,
        through: DateTime(2026, 4, 30),
      );
      expect(dates, [
        DateTime(2026, 1, 31),
        DateTime(2026, 2, 28), // 2026 is not a leap year
        DateTime(2026, 3, 31),
        DateTime(2026, 4, 30),
      ]);
    });

    test('day 29 reaches the 29th in a leap February', () {
      final dates = SipMath.generateSchedule(
        start: DateTime(2028, 1, 29),
        frequency: SipFrequency.monthly,
        day: 29,
        through: DateTime(2028, 2, 29),
      );
      expect(dates.last, DateTime(2028, 2, 29));
    });

    test('a start after the chosen day skips that month', () {
      final dates = SipMath.generateSchedule(
        start: DateTime(2026, 1, 20),
        frequency: SipFrequency.monthly,
        day: 5,
        through: DateTime(2026, 3, 10),
      );
      expect(dates, [DateTime(2026, 2, 5), DateTime(2026, 3, 5)]);
    });

    test('quarterly steps three months', () {
      final dates = SipMath.generateSchedule(
        start: DateTime(2026, 1, 10),
        frequency: SipFrequency.quarterly,
        day: 10,
        through: DateTime(2026, 12, 31),
      );
      expect(dates, [
        DateTime(2026, 1, 10),
        DateTime(2026, 4, 10),
        DateTime(2026, 7, 10),
        DateTime(2026, 10, 10),
      ]);
    });

    test('weekly repeats on the chosen weekday', () {
      // 1 Jan 2026 is a Thursday; asking for Monday starts on the 5th.
      final dates = SipMath.generateSchedule(
        start: DateTime(2026, 1, 1),
        frequency: SipFrequency.weekly,
        day: DateTime.monday,
        through: DateTime(2026, 1, 26),
      );
      expect(dates, [
        DateTime(2026, 1, 5),
        DateTime(2026, 1, 12),
        DateTime(2026, 1, 19),
        DateTime(2026, 1, 26),
      ]);
      expect(dates.every((d) => d.weekday == DateTime.monday), isTrue);
    });

    test('never generates past today', () {
      final dates = SipMath.generateSchedule(
        start: DateTime(2026, 1, 5),
        frequency: SipFrequency.monthly,
        day: 5,
        through: DateTime(2026, 3, 4), // the day before the March debit
      );
      expect(dates.last, DateTime(2026, 2, 5));
    });

    test('a start before inception is clamped to the first NAV', () {
      final dates = SipMath.generateSchedule(
        start: DateTime(2025, 10, 5),
        frequency: SipFrequency.monthly,
        day: 5,
        through: DateTime(2026, 2, 28),
        notBefore: DateTime(2026, 1, 1),
      );
      expect(dates, [DateTime(2026, 1, 5), DateTime(2026, 2, 5)]);
    });

    test('an empty span produces nothing', () {
      expect(
        SipMath.generateSchedule(
          start: DateTime(2026, 5, 1),
          frequency: SipFrequency.monthly,
          day: 1,
          through: DateTime(2026, 4, 1),
        ),
        isEmpty,
      );
    });
  });

  group('NAV resolution', () {
    final series = _weekdaySeries(DateTime(2026, 1, 1), DateTime(2026, 1, 31));

    test('allotment walks FORWARD over a weekend', () {
      // Saturday 3 Jan 2026 → Monday 5 Jan.
      final resolved =
          SipMath.resolveAllotmentDate(DateTime(2026, 1, 3), series);
      expect(resolved, DateTime(2026, 1, 5));
    });

    test('valuation walks BACKWARD over a weekend', () {
      // Sunday 4 Jan → Friday 2 Jan. The opposite direction to allotment;
      // swapping them silently produces wrong units.
      final resolved =
          SipMath.resolveValuationDate(DateTime(2026, 1, 4), series);
      expect(resolved, DateTime(2026, 1, 2));
    });

    test('an exact match resolves to itself in both directions', () {
      final day = DateTime(2026, 1, 7); // a Wednesday
      expect(SipMath.resolveAllotmentDate(day, series), day);
      expect(SipMath.resolveValuationDate(day, series), day);
    });

    test('no NAV within the forward window leaves it unresolved', () {
      final sparse = _series({DateTime(2026, 1, 1): 100});
      expect(
        SipMath.resolveAllotmentDate(DateTime(2026, 1, 2), sparse),
        isNull,
        reason: 'the next NAV is more than 7 days away',
      );
    });

    test('valuation gives up beyond its backward window', () {
      final sparse = _series({DateTime(2026, 1, 1): 100});
      expect(
        SipMath.resolveValuationDate(DateTime(2026, 1, 20), sparse),
        isNull,
      );
    });
  });

  group('units and totals', () {
    test('a resolved installment buys amount ÷ NAV units', () {
      final i = Installment(
          date: DateTime(2026, 1, 5), amount: 5000, nav: 100);
      expect(i.units, 50);
      expect(i.investedAmount, 5000);
    });

    test('a skipped installment counts for nothing', () {
      final i = Installment(
          date: DateTime(2026, 1, 5), amount: 5000, nav: 100, skipped: true);
      expect(i.units, 0);
      expect(i.investedAmount, 0);
    });

    test('an unresolved installment buys no units rather than guessing', () {
      final i = Installment(date: DateTime(2026, 1, 5), amount: 5000);
      expect(i.isResolved, isFalse);
      expect(i.units, 0);
      expect(i.investedAmount, 5000,
          reason: 'the money did leave the account, even if units are pending');
    });

    test('an override wins over the arithmetic', () {
      // Brokers deduct stamp duty before allotting, so their figure is a shade
      // lower than amount ÷ NAV.
      final i = Installment(
          date: DateTime(2026, 1, 5),
          amount: 5000,
          nav: 100,
          unitsOverride: 49.9975);
      expect(i.units, 49.9975);
    });

    test('totals sum units and invested across the ledger', () {
      final list = [
        Installment(date: DateTime(2026, 1, 5), amount: 5000, nav: 100),
        Installment(date: DateTime(2026, 2, 5), amount: 5000, nav: 125),
        Installment(
            date: DateTime(2026, 3, 5), amount: 5000, nav: 125, skipped: true),
      ];
      expect(SipMath.totalUnits(list), 90); // 50 + 40 + 0
      expect(SipMath.totalInvested(list), 10000);
    });
  });

  group('valuation', () {
    test('values units at the NAV in force on the day', () {
      final series = _weekdaySeries(DateTime(2026, 1, 1), DateTime(2026, 1, 31),
          start: 100);
      final list = [
        Installment(date: DateTime(2026, 1, 5), amount: 5000, nav: 100),
      ];
      expect(SipMath.valueOn(list, series, DateTime(2026, 1, 9)), 5000);
    });

    test('installments after the valuation date are not counted yet', () {
      final series = _weekdaySeries(DateTime(2026, 1, 1), DateTime(2026, 1, 31));
      final list = [
        Installment(date: DateTime(2026, 1, 5), amount: 5000, nav: 100),
        Installment(date: DateTime(2026, 1, 20), amount: 5000, nav: 100),
      ];
      expect(SipMath.valueOn(list, series, DateTime(2026, 1, 9)), 5000);
    });

    test('no NAV in range gives null, not zero', () {
      final sparse = _series({DateTime(2025, 1, 1): 100});
      final list = [
        Installment(date: DateTime(2026, 1, 5), amount: 5000, nav: 100)
      ];
      expect(SipMath.valueOn(list, sparse, DateTime(2026, 1, 9)), isNull);
    });
  });

  group('XIRR', () {
    test('a single lump sum that grew 12% over a year returns ≈0.12', () {
      final list = [
        Installment(date: DateTime(2026, 1, 1), amount: 100000, nav: 100),
      ];
      final rate =
          SipMath.xirr(list, 112000, DateTime(2027, 1, 1));
      expect(rate, isNotNull);
      expect(rate!, closeTo(0.12, 0.002));
    });

    test('a flat holding returns approximately zero', () {
      final list = [
        Installment(date: DateTime(2026, 1, 1), amount: 100000, nav: 100),
      ];
      final rate = SipMath.xirr(list, 100000, DateTime(2027, 1, 1));
      expect(rate!, closeTo(0, 1e-6));
    });

    test('a loss returns a negative rate', () {
      final list = [
        Installment(date: DateTime(2026, 1, 1), amount: 100000, nav: 100),
      ];
      final rate = SipMath.xirr(list, 80000, DateTime(2027, 1, 1));
      expect(rate!, lessThan(0));
    });

    test('monthly contributions solve to a sensible rate', () {
      final list = [
        for (var m = 1; m <= 12; m++)
          Installment(date: DateTime(2026, m, 1), amount: 5000, nav: 100),
      ];
      // 60,000 invested evenly over a year, worth 65,000 at the end: the money
      // was only invested for ~6.5 months on average, so the annualised rate is
      // well above the 8.3% simple return.
      final rate = SipMath.xirr(list, 65000, DateTime(2027, 1, 1));
      expect(rate, isNotNull);
      expect(rate!, greaterThan(0.08));
      expect(rate, lessThan(0.30));
    });

    test('skipped installments are excluded from the flows', () {
      final withSkip = [
        Installment(date: DateTime(2026, 1, 1), amount: 100000, nav: 100),
        Installment(
            date: DateTime(2026, 6, 1),
            amount: 100000,
            nav: 100,
            skipped: true),
      ];
      final without = [
        Installment(date: DateTime(2026, 1, 1), amount: 100000, nav: 100),
      ];
      expect(SipMath.xirr(withSkip, 112000, DateTime(2027, 1, 1)),
          SipMath.xirr(without, 112000, DateTime(2027, 1, 1)));
    });

    test('too short a span returns null rather than an absurd annual rate', () {
      final list = [
        Installment(date: DateTime(2026, 1, 1), amount: 100000, nav: 100),
      ];
      expect(SipMath.xirr(list, 101000, DateTime(2026, 1, 20)), isNull);
    });

    test('no contributions, or no value, returns null', () {
      expect(SipMath.xirr(const [], 1000, DateTime(2027, 1, 1)), isNull);
      expect(
        SipMath.xirr(
          [Installment(date: DateTime(2026, 1, 1), amount: 1000, nav: 10)],
          0,
          DateTime(2027, 1, 1),
        ),
        isNull,
      );
    });
  });

  group('value series', () {
    test('both lines are cumulative as at each point', () {
      final series = _weekdaySeries(DateTime(2026, 1, 1), DateTime(2026, 3, 31),
          start: 100, dailyGrowth: 1);
      final list = [
        Installment(date: DateTime(2026, 1, 5), amount: 5000, nav: 100),
        Installment(date: DateTime(2026, 2, 5), amount: 5000, nav: 131),
      ];

      final points = SipMath.valueSeries(list, series, [
        DateTime(2026, 1, 9),
        DateTime(2026, 2, 9),
        DateTime(2026, 3, 9),
      ]);

      expect(points, hasLength(3));
      expect(points[0].invested, 5000, reason: 'only the first installment');
      expect(points[1].invested, 10000);
      expect(points[2].invested, 10000);
      // Value rises with NAV, and outpaces invested capital in a rising market.
      expect(points[2].value, greaterThan(points[1].value));
      expect(points[2].value, greaterThan(points[2].invested));
    });

    test('a point before any NAV falls back to invested capital', () {
      final series = _weekdaySeries(DateTime(2026, 2, 1), DateTime(2026, 2, 28));
      final list = [
        Installment(date: DateTime(2026, 2, 5), amount: 5000, nav: 100),
      ];
      final points =
          SipMath.valueSeries(list, series, [DateTime(2025, 12, 1)]);
      expect(points.single.value, points.single.invested);
    });
  });
}
