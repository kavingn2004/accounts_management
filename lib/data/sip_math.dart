import 'dart:math' as math;

import 'nav_api.dart';

/// How often a SIP debits.
enum SipFrequency { weekly, monthly, quarterly }

SipFrequency sipFrequencyFrom(Object? value) => switch (
    (value ?? 'monthly').toString().toLowerCase()) {
      'weekly' => SipFrequency.weekly,
      'quarterly' => SipFrequency.quarterly,
      _ => SipFrequency.monthly,
    };

/// One installment as the math sees it: what was paid, when, and what it
/// bought. Storage shape lives in the service, not here.
class Installment {
  const Installment({
    required this.date,
    required this.amount,
    this.nav,
    this.navDate,
    this.skipped = false,
    this.unitsOverride,
  });

  final DateTime date;
  final double amount;

  /// NAV the units were allotted at, and the published date it belongs to.
  /// Null while unresolved — no NAV within the forward window.
  final double? nav;
  final DateTime? navDate;

  /// Excluded from units and invested totals, but kept visible in the ledger.
  final bool skipped;

  /// Exact units pasted in from the broker, overriding `amount / nav`.
  /// Brokers deduct stamp duty before allotting, so their figure is fractionally
  /// lower than the arithmetic — see the spec's "known variance".
  final double? unitsOverride;

  bool get isResolved => unitsOverride != null || (nav != null && nav! > 0);

  /// Units this installment bought. Zero while skipped or unresolved, so a
  /// missing NAV can never inflate a holding.
  double get units {
    if (skipped) return 0;
    if (unitsOverride != null) return unitsOverride!;
    final n = nav;
    if (n == null || n <= 0) return 0;
    return amount / n;
  }

  /// Rupees that count towards invested capital.
  double get investedAmount => skipped ? 0 : amount;
}

/// Pure SIP arithmetic: schedules, NAV resolution, units, returns.
///
/// No I/O, no storage, no Flutter. Everything here is a function of its
/// arguments, which is what makes the numbers testable against fixtures.
class SipMath {
  const SipMath._();

  static DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Last day of the month [d] falls in.
  static int daysInMonth(int year, int month) =>
      DateTime(year, month + 1, 0).day;

  /// Every installment date from [start] through [through] inclusive.
  ///
  /// Monthly and quarterly land on [day] of the month, clamped to the month's
  /// length — a SIP set to the 31st debits on the 28th of February, exactly as
  /// a bank mandate does, rather than skipping the month or spilling into
  /// March. Weekly treats [day] as a weekday (1 = Monday).
  ///
  /// [notBefore] drops dates preceding a fund's inception; generation never
  /// runs past [through], so future installments are not pre-created.
  static List<DateTime> generateSchedule({
    required DateTime start,
    required SipFrequency frequency,
    required int day,
    required DateTime through,
    DateTime? notBefore,
  }) {
    final from = dayOf(start);
    final end = dayOf(through);
    if (from.isAfter(end)) return const [];

    final dates = <DateTime>[];

    if (frequency == SipFrequency.weekly) {
      final weekday = day.clamp(1, 7);
      var cursor = from;
      // Walk forward to the first matching weekday on or after the start.
      while (cursor.weekday != weekday && !cursor.isAfter(end)) {
        cursor = cursor.add(const Duration(days: 1));
      }
      while (!cursor.isAfter(end)) {
        dates.add(cursor);
        cursor = cursor.add(const Duration(days: 7));
      }
    } else {
      final step = frequency == SipFrequency.quarterly ? 3 : 1;
      final wanted = day.clamp(1, 31);
      var year = from.year;
      var month = from.month;
      // The first occurrence in the starting month may already have passed.
      var candidate =
          DateTime(year, month, math.min(wanted, daysInMonth(year, month)));
      if (candidate.isBefore(from)) {
        month += step;
        year += (month - 1) ~/ 12;
        month = (month - 1) % 12 + 1;
        candidate =
            DateTime(year, month, math.min(wanted, daysInMonth(year, month)));
      }
      while (!candidate.isAfter(end)) {
        dates.add(candidate);
        month += step;
        year += (month - 1) ~/ 12;
        month = (month - 1) % 12 + 1;
        candidate =
            DateTime(year, month, math.min(wanted, daysInMonth(year, month)));
      }
    }

    if (notBefore == null) return dates;
    final floor = dayOf(notBefore);
    return dates.where((d) => !d.isBefore(floor)).toList();
  }

  /// The NAV date an installment is allotted at: **walk forward**.
  ///
  /// NAV is published only on business days, so a SIP debited on a Sunday is
  /// allotted at Monday's NAV. Returns null when nothing is published within
  /// [maxForwardDays] — the installment stays unresolved rather than being
  /// valued at a guess.
  static DateTime? resolveAllotmentDate(
    DateTime installment,
    NavSeries series, {
    int maxForwardDays = 7,
  }) {
    var cursor = dayOf(installment);
    for (var i = 0; i <= maxForwardDays; i++) {
      if (series.navOn(cursor) != null) return cursor;
      cursor = cursor.add(const Duration(days: 1));
    }
    return null;
  }

  /// The NAV date a valuation uses: **walk backward**.
  ///
  /// Today's NAV is published late evening IST, so during the day the newest
  /// available figure is yesterday's. This is the opposite rule to allotment,
  /// and swapping the two silently produces wrong units.
  static DateTime? resolveValuationDate(
    DateTime target,
    NavSeries series, {
    int maxBackDays = 10,
  }) {
    var cursor = dayOf(target);
    for (var i = 0; i <= maxBackDays; i++) {
      if (series.navOn(cursor) != null) return cursor;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return null;
  }

  /// Total units held across [installments].
  static double totalUnits(Iterable<Installment> installments) =>
      installments.fold(0.0, (a, i) => a + i.units);

  /// Total rupees invested, excluding skipped installments.
  static double totalInvested(Iterable<Installment> installments) =>
      installments.fold(0.0, (a, i) => a + i.investedAmount);

  /// Units × the NAV in force on [asOf], or null when no NAV is close enough.
  static double? valueOn(
    Iterable<Installment> installments,
    NavSeries series,
    DateTime asOf,
  ) {
    final navDate = resolveValuationDate(asOf, series);
    if (navDate == null) return null;
    final nav = series.navOn(navDate)!;
    final units = installments
        .where((i) => !i.date.isAfter(asOf))
        .fold(0.0, (a, i) => a + i.units);
    return units * nav;
  }

  /// Annualised return over irregular cash flows.
  ///
  /// Newton–Raphson from 10%, falling back to bisection when the derivative
  /// collapses. Returns null rather than a misleading figure when the inputs
  /// cannot support one: fewer than two flows, a span under 30 days, or no
  /// convergence.
  static double? xirr(
    List<Installment> installments,
    double currentValue,
    DateTime asOf,
  ) {
    final flows = <(DateTime, double)>[
      for (final i in installments)
        if (!i.skipped && !i.date.isAfter(asOf)) (dayOf(i.date), -i.amount),
    ];
    if (flows.isEmpty || currentValue <= 0) return null;
    flows.add((dayOf(asOf), currentValue));
    if (flows.length < 2) return null;

    flows.sort((a, b) => a.$1.compareTo(b.$1));
    final origin = flows.first.$1;
    if (flows.last.$1.difference(origin).inDays < 30) return null;

    final years = [
      for (final f in flows) f.$1.difference(origin).inDays / 365.0,
    ];
    final amounts = [for (final f in flows) f.$2];

    double npv(double r) {
      var total = 0.0;
      for (var i = 0; i < amounts.length; i++) {
        total += amounts[i] / math.pow(1 + r, years[i]);
      }
      return total;
    }

    var rate = 0.10;
    for (var iteration = 0; iteration < 100; iteration++) {
      final value = npv(rate);
      if (value.abs() < 1e-7) return rate;

      var derivative = 0.0;
      for (var i = 0; i < amounts.length; i++) {
        derivative +=
            -years[i] * amounts[i] / math.pow(1 + rate, years[i] + 1);
      }
      if (derivative.abs() < 1e-12) break;

      final next = rate - value / derivative;
      if (next.isNaN || next.isInfinite || next <= -0.999) break;
      if ((next - rate).abs() < 1e-9) return next;
      rate = next;
    }

    return _bisect(npv);
  }

  /// Last-resort root find over a wide bracket. Null when the function does not
  /// change sign across it, which means no rate explains these flows.
  static double? _bisect(double Function(double) npv) {
    var low = -0.99;
    var high = 10.0;
    var fLow = npv(low);
    var fHigh = npv(high);
    if (fLow.isNaN || fHigh.isNaN || fLow * fHigh > 0) return null;

    for (var i = 0; i < 200; i++) {
      final mid = (low + high) / 2;
      final fMid = npv(mid);
      if (fMid.abs() < 1e-7) return mid;
      if (fLow * fMid < 0) {
        high = mid;
        fHigh = fMid;
      } else {
        low = mid;
        fLow = fMid;
      }
    }
    return (low + high) / 2;
  }

  /// Value and invested capital at each of [points], for the detail chart.
  ///
  /// Both lines are cumulative as at each date, so the gap between them is the
  /// gain on that day rather than on the day the chart was drawn.
  static List<({DateTime date, double value, double invested})> valueSeries(
    List<Installment> installments,
    NavSeries series,
    List<DateTime> points,
  ) {
    final sorted = [...installments]..sort((a, b) => a.date.compareTo(b.date));
    final out = <({DateTime date, double value, double invested})>[];

    for (final point in points) {
      var units = 0.0;
      var invested = 0.0;
      for (final i in sorted) {
        if (i.date.isAfter(point)) break;
        units += i.units;
        invested += i.investedAmount;
      }
      final navDate = resolveValuationDate(point, series);
      final nav = navDate == null ? null : series.navOn(navDate);
      out.add((
        date: point,
        value: nav == null ? invested : units * nav,
        invested: invested,
      ));
    }
    return out;
  }
}
