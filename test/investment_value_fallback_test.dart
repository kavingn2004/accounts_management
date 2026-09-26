import 'package:accounts_app/data/finance_math.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// A holding is never worth nothing just because nobody typed a figure in.
///
/// Two ways a row legitimately arrives with no `current_value`:
///   - it was added with only an invested amount (the field is optional), and
///   - a SIP was created today, before the fund published a NAV to allot at.
///
/// Both used to read ₹0 on the row and contribute ₹0 to net worth, which
/// understates the portfolio by the entire cost of the holding.
void main() {
  group('investmentValue', () {
    test('uses current_value when one is stated', () {
      expect(
        investmentValue({'current_value': 58200, 'invested_amount': 50000}),
        58200,
      );
    });

    test('falls back to what was invested when none is stated', () {
      expect(
        investmentValue({'invested_amount': 500, 'total_invested': 500}),
        500,
      );
    });

    test('prefers the running total over the first contribution', () {
      // total_invested grows with every top-up; invested_amount is the opening
      // figure, so the former is the better estimate of cost.
      expect(
        investmentValue({'invested_amount': 500, 'total_invested': 1500}),
        1500,
      );
    });

    test('a SIP awaiting its first allotment is worth what it cost', () {
      // Units are 0 because the NAV for today has not been published; the money
      // has still left the account.
      expect(
        investmentValue({
          'type': 'sip',
          'quantity': 0,
          'total_invested': 500,
        }),
        500,
      );
    });

    test('a deliberate zero is respected, not overridden', () {
      expect(
        investmentValue({'current_value': 0, 'invested_amount': 500}),
        0,
        reason: 'a holding written off is worth zero, and must stay zero',
      );
    });

    test('a row with nothing at all is zero, not an error', () {
      expect(investmentValue(<String, dynamic>{}), 0);
    });
  });

  group('net worth', () {
    Json worth(List<Json> investments) => FinanceMath.dashboard(
          balances: const {'Cash': 1000},
          income: const [],
          expenses: const [],
          investments: investments,
          savingsGoals: const [],
          debtors: const [],
          creditors: const [],
          loans: const [],
          bills: const [],
        );

    test('counts a value-less holding at its cost', () {
      final d = worth([
        {'name': 'mid cap', 'type': 'mf', 'invested_amount': 500,
          'total_invested': 500},
      ]);
      expect(d['investment_worth'], 500);
      expect(d['net_worth'], 1500, reason: '₹1,000 cash + ₹500 holding');
    });

    test('counts a SIP with unallotted units at its cost', () {
      final d = worth([
        {'name': 'mid cap', 'type': 'sip', 'quantity': 0, 'total_invested': 500},
      ]);
      expect(d['investment_worth'], 500);
    });

    test('a priced holding still counts at its price', () {
      final d = worth([
        {'name': 'Nifty', 'current_value': 58200, 'total_invested': 50000},
      ]);
      expect(d['investment_worth'], 58200);
    });
  });
}
