import 'package:accounts_app/core/formatters.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/services/sip_service.dart';
import 'package:flutter_test/flutter_test.dart';

NavSeries _flat() {
  final navs = <DateTime, double>{};
  var cursor = DateTime(2026, 1, 1);
  while (cursor.isBefore(DateTime(2026, 12, 31))) {
    navs[cursor] = 100;
    cursor = cursor.add(const Duration(days: 1));
  }
  return NavSeries(code: 1, schemeName: 'F', fundHouse: 'H', navs: navs);
}

Json _row({List<Json>? changes}) => {
      'id': '1',
      'name': 'Step-up SIP',
      'type': 'sip',
      'scheme_code': 1,
      'sip_amount': 5000,
      'sip_frequency': 'monthly',
      'sip_day': 5,
      'sip_start_date': '2026-01-05',
      'sip_active': true,
      if (changes != null) 'sip_amount_changes': changes,
    };

void main() {
  group('amount in force', () {
    test('is the base amount when nothing has changed', () {
      expect(SipService.amountOn(_row(), DateTime(2026, 6, 5)), 5000);
    });

    test('switches on the date a step-up takes effect', () {
      final row = _row(changes: [
        {'from': '2026-04-01', 'amount': 7500},
      ]);
      expect(SipService.amountOn(row, DateTime(2026, 3, 5)), 5000);
      expect(SipService.amountOn(row, DateTime(2026, 4, 1)), 7500,
          reason: 'inclusive of the effective date');
      expect(SipService.amountOn(row, DateTime(2026, 5, 5)), 7500);
    });

    test('applies the latest of several step-ups', () {
      final row = _row(changes: [
        {'from': '2026-06-01', 'amount': 10000},
        {'from': '2026-04-01', 'amount': 7500},
      ]);
      // Deliberately out of order — they are sorted before use.
      expect(SipService.amountOn(row, DateTime(2026, 5, 5)), 7500);
      expect(SipService.amountOn(row, DateTime(2026, 7, 5)), 10000);
    });

    test('ignores malformed entries rather than throwing', () {
      final row = _row(changes: [
        {'from': 'not-a-date', 'amount': 9999},
        {'amount': 8888},
        {'from': '2026-04-01'},
      ]);
      expect(SipService.amountOn(row, DateTime(2026, 12, 5)), 5000);
    });
  });

  group('derived schedule', () {
    test('past installments keep the amount they were actually paid at', () {
      final row = _row(changes: [
        {'from': '2026-04-01', 'amount': 7500},
      ]);

      final derived =
          SipService.derive(row, _flat(), now: DateTime(2026, 5, 20));

      expect(derived.map((e) => e['amount']), [5000, 5000, 5000, 7500, 7500]);
      // Units follow: 50 a month, then 75.
      final units =
          derived.fold<double>(0, (a, e) => a + (e['units'] as num).toDouble());
      expect(units, 50 * 3 + 75 * 2);
    });

    test('a step-up dated in the future changes nothing yet', () {
      final row = _row(changes: [
        {'from': '2026-11-01', 'amount': 7500},
      ]);
      final derived =
          SipService.derive(row, _flat(), now: DateTime(2026, 5, 20));
      expect(derived.every((e) => e['amount'] == 5000), isTrue);
    });
  });

  group('unit formatting', () {
    test('fractional units read at fund-house precision', () {
      // What the screen was showing before: 2.61858342317984.
      expect(quantityText(2.61858342317984), '2.619');
      expect(quantityText(8.765163733258538), '8.765');
    });

    test('whole and short values stay clean', () {
      expect(quantityText(12), '12');
      expect(quantityText(2.5), '2.5');
      expect(quantityText(0.35), '0.35');
    });
  });
}
