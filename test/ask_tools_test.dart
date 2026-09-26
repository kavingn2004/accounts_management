import 'package:accounts_app/services/ask/ask_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// A small but realistic portfolio: two months of spending, an account with
/// movements, a plain holding and a SIP with a ledger.
AskData _data() => const AskData(
      income: [
        {'date': '2026-07-05', 'amount': 40000, 'source': 'Salary',
          'account': 'INDIAN BANK'},
        {'date': '2026-08-05', 'amount': 40000, 'source': 'Salary',
          'account': 'INDIAN BANK'},
      ],
      expenses: [
        {'date': '2026-07-03', 'amount': 8000, 'payee': 'Rent',
          'account': 'INDIAN BANK'},
        {'date': '2026-07-11', 'amount': 2200, 'payee': 'Groceries',
          'account': 'INDIAN BANK'},
        {'date': '2026-07-19', 'amount': 900, 'payee': 'Groceries'},
        {'date': '2026-08-02', 'amount': 8000, 'payee': 'Rent'},
        {'date': '2026-08-04', 'amount': 1500, 'payee': 'Bike service'},
      ],
      accounts: [
        {'name': 'INDIAN BANK', 'type': 'bank', 'opening_balance': 5000},
        {'name': 'Wallet', 'type': 'cash', 'opening_balance': 1000},
      ],
      investments: [
        {
          'id': 'inv1',
          'name': 'Nifty 50 Index',
          'type': 'fund',
          'total_invested': 10000,
          'current_value': 12000,
        },
        {
          'id': 'sip1',
          'name': 'Tata Large & Mid Cap',
          'type': 'sip',
          'scheme_code': 120503,
          'last_price': 580.85,
          'total_invested': 4000,
          'current_value': 4200,
        },
      ],
      installments: [
        {'parent_id': 'sip1', 'date': '2026-07-09', 'amount': 2000,
          'nav': 500, 'units': 4},
        {'parent_id': 'sip1', 'date': '2026-08-09', 'amount': 2000,
          'nav': 580.85, 'units': 3.443},
      ],
    );

AskAnswer _run(String tool, [Map<String, dynamic> args = const {}]) =>
    AskTools.byName(tool)!.run(_data(), args);

void main() {
  group('spend_by_payee', () {
    test('totals and ranks every payee in a period', () {
      final a = _run('spend_by_payee',
          {'from': '2026-07-01', 'to': '2026-07-31'});

      // 8000 + 2200 + 900
      expect(a.text, contains('₹11,100'));
      expect(a.text, contains('Rent'), reason: 'the largest leads');
      expect(a.rows.first.label, 'Rent');
      expect(a.rows[1].label, 'Groceries');
      expect(a.rows[1].value, '₹3,100', reason: 'both entries summed');
    });

    test('filters to one payee when asked', () {
      final a = _run('spend_by_payee', {'payee': 'groceries'});
      expect(a.text, contains('₹3,100'));
      expect(a.rows, hasLength(1));
    });

    test('says so plainly when nothing matches', () {
      final a = _run('spend_by_payee', {'payee': 'yacht'});
      expect(a.text, contains('No spending'));
      expect(a.rows, isEmpty);
    });

    test('a period with no end still works', () {
      final a = _run('spend_by_payee', {'from': '2026-08-01'});
      expect(a.text, contains('₹9,500')); // 8000 + 1500
    });
  });

  group('income_vs_expense', () {
    test('reports what was kept', () {
      final a = _run('income_vs_expense',
          {'from': '2026-07-01', 'to': '2026-07-31'});
      expect(a.text, contains('₹40,000'));
      expect(a.text, contains('₹11,100'));
      expect(a.text, contains('keeping ₹28,900'));
    });

    test('says outright when more went out than came in', () {
      final a = _run('income_vs_expense',
          {'from': '2026-08-01', 'to': '2026-08-03'});
      // ₹0 in, ₹8,000 out.
      expect(a.text, contains('more than came in'));
    });
  });

  group('account_balances', () {
    test('computes from opening balance plus every movement', () {
      final a = _run('account_balances', {'account': 'indian'});
      // 5000 + 80000 income − 10200 expenses on that account
      expect(a.text, contains('₹74,800'));
      expect(a.rows, hasLength(1));
    });

    test('lists them all when no account is named', () {
      final a = _run('account_balances');
      expect(a.rows, hasLength(2));
      expect(a.text, contains('2 accounts'));
    });
  });

  group('investment_summary', () {
    test('nets cost against value across holdings', () {
      final a = _run('investment_summary');
      expect(a.text, contains('₹16,200')); // 12000 + 4200
      expect(a.text, contains('₹14,000')); // 10000 + 4000
      expect(a.text, contains('up ₹2,200'));
      expect(a.rows, hasLength(2));
    });
  });

  group('sip_detail', () {
    test('reads units and value from the installment ledger', () {
      final a = _run('sip_detail', {'name': 'tata'});
      expect(a.text, contains('7.443'), reason: '4 + 3.443 units');
      expect(a.text, contains('₹580.85'));
      expect(a.text, contains('₹4,000'), reason: 'invested');
    });

    test('names the miss rather than guessing', () {
      final a = _run('sip_detail', {'name': 'hdfc'});
      expect(a.text, contains('No SIP matches'));
    });
  });

  group('largest_expenses', () {
    test('ranks individual entries', () {
      final a = _run('largest_expenses', {'limit': '3'});
      expect(a.rows, hasLength(3));
      expect(a.rows.first.value, '₹8,000');
      expect(a.text, contains('Rent'));
    });

    test('clamps a silly limit rather than failing', () {
      expect(_run('largest_expenses', {'limit': '9999'}).rows, hasLength(5));
    });
  });

  group('net_worth', () {
    // Deliberately its own fixture: every component present exactly once, so
    // the arithmetic can be checked by hand.
    const rich = AskData(
      accounts: [{'name': 'Bank', 'type': 'bank', 'opening_balance': 10000}],
      investments: [{'total_invested': 5000, 'current_value': 7000}],
      savings: [{'saved_amount': 3000, 'target_amount': 10000}],
      debtors: [{'name': 'Anand', 'amount': 2000}],
      creditors: [{'name': 'Ravi', 'amount': 1500}],
      loans: [{'status': 'active', 'outstanding': 4000}],
      bills: [{'amount': 500}],
    );

    AskAnswer run() => AskTools.byName('net_worth')!.run(rich, const {});

    test('adds what you have and subtracts what you owe', () {
      // 10,000 + 7,000 + 3,000 + 2,000 − 1,500 − 4,000
      expect(run().text, contains('₹16,500'));
    });

    test('the breakdown reconciles with the headline', () {
      final rows = run().rows;
      final sum = rows.fold(0.0, (a, r) {
        final n = double.parse(
            r.value.replaceAll(RegExp(r'[₹,−-]'), '').trim());
        return a + (r.value.startsWith('−') ? -n : n);
      });
      expect(sum, 16500,
          reason: 'a breakdown that does not add up to the total is worse '
              'than no breakdown: ${rows.map((r) => '${r.label} ${r.value}')}');
    });

    test('leaves out the parts that are zero', () {
      const bare = AskData(
        accounts: [{'name': 'Bank', 'type': 'bank', 'opening_balance': 800}],
      );
      final a = AskTools.byName('net_worth')!.run(bare, const {});
      expect(a.text, contains('₹800'));
      expect(a.rows.map((r) => r.label), ['In accounts']);
    });

    test('says so plainly when there is nothing recorded', () {
      final a = AskTools.byName('net_worth')!.run(const AskData(), const {});
      expect(a.rows, isEmpty);
      expect(a.text, contains('nothing recorded'));
    });

    test('a settled debt is not still counted', () {
      const settled = AskData(
        debtors: [{'name': 'Anand', 'amount': 2000, 'status': 'settled'}],
      );
      expect(AskTools.byName('net_worth')!.run(settled, const {}).rows,
          isEmpty);
    });
  });

  test('every tool is registered under its own name', () {
    for (final t in AskTools.all) {
      expect(AskTools.byName(t.name), same(t));
      expect(t.description, isNotEmpty,
          reason: 'the description is what the model picks from');
    }
    expect(AskTools.byName('drop_table'), isNull);
  });
}
