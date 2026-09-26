import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/services/ask/ask_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records with the kind of names that mean nothing to a keyword router but
/// everything to the person asking.
class _Repo implements FinanceRepository {
  @override
  Future<List<Json>> list(String t,
      {String orderBy = 'created_at', bool ascending = false}) async {
    switch (t) {
      case 'expenses':
        return [
          {'date': '2026-08-02', 'amount': 1200, 'payee': 'Kiki'},
          {'date': '2026-08-06', 'amount': 800, 'payee': 'Kiki'},
          {'date': '2026-08-04', 'amount': 2000, 'payee': 'Rent'},
        ];
      case 'debtors':
        return [
          {'person_name': 'Jana', 'amount': 5000, 'status': 'open',
            'due_date': '2026-09-01'},
          {'person_name': 'Ravi', 'amount': 1500, 'status': 'open'},
          {'person_name': 'Old Debt', 'amount': 0, 'status': 'settled'},
        ];
      case 'creditors':
        return [
          {'person_name': 'Anita', 'amount': 8000, 'status': 'partial'},
        ];
      case 'accounts':
        return [
          {'name': 'INDIAN BANK', 'type': 'bank', 'opening_balance': 1000},
        ];
      case 'investments':
        return [
          {'id': '1', 'name': 'Tata Mid Cap', 'type': 'sip',
            'scheme_code': 1, 'total_invested': 5000, 'current_value': 5500},
        ];
    }
    return const [];
  }

  @override
  Future<void> insert(String t, Json v) async {}
  @override
  Future<void> update(String t, String id, Json v) async {}
  @override
  Future<void> delete(String t, String id) async {}
  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

Future<AskResult> ask(String q) =>
    AskService(repo: _Repo(), clock: () => DateTime(2026, 8, 15)).ask(q);

void main() {
  group('debts', () {
    test('who owes me, totalled and listed', () async {
      final r = await ask('who owes me money');
      expect(r.tool, 'money_owed_to_me');
      expect(r.answer.text, contains('₹6,500')); // 5000 + 1500
      expect(r.answer.rows, hasLength(2),
          reason: 'the settled debt is not money owed');
    });

    test('who I owe', () async {
      final r = await ask('who do i owe');
      expect(r.tool, 'money_i_owe');
      expect(r.answer.text, contains('Anita'));
      expect(r.answer.text, contains('₹8,000'));
    });

    test('"my debtors" and "my creditors" both land', () async {
      expect((await ask('show my debtors')).tool, 'money_owed_to_me');
      expect((await ask('my creditors')).tool, 'money_i_owe');
    });

    test('a due date is shown beside the amount', () async {
      final r = await ask('who owes me');
      expect(r.answer.rows.first.label, contains('due'));
    });
  });

  group('names from the data', () {
    test('a debtor by name goes to the debt tool, not spending', () async {
      final r = await ask('what about jana');
      expect(r.tool, 'money_owed_to_me');
      expect(r.answer.text, contains('Jana owes you ₹5,000'));
    });

    test('a creditor by name', () async {
      final r = await ask('anita');
      expect(r.tool, 'money_i_owe');
      expect(r.answer.text, contains('₹8,000'));
    });

    test('a payee by name filters spending to them', () async {
      final r = await ask('how much for kiki');
      expect(r.tool, 'spend_by_payee');
      expect(r.args['payee'], 'kiki');
      expect(r.answer.text, contains('₹2,000'), reason: '1200 + 800');
    });

    test('a payee name still respects the period', () async {
      final r = await ask('kiki last month');
      expect(r.args['payee'], 'kiki');
      expect(r.args['period'], 'last_month');
    });

    test('an account by name', () async {
      final r = await ask('indian bank');
      expect(r.tool, 'account_balances');
      expect(r.args['account'], 'indian bank');
    });

    test('a holding by name', () async {
      expect((await ask('how is tata mid cap doing')).tool,
          'investment_summary');
      expect((await ask('tata mid cap sip')).tool, 'sip_detail');
    });

    test('an unknown name falls back rather than inventing a match', () async {
      final r = await ask('how much for zzzz');
      expect(r.tool, 'spend_by_payee');
      expect(r.args.containsKey('payee'), isFalse);
    });

    test('a name is matched whole, not as a fragment', () async {
      // "ravi" must not match inside another word.
      const entities = AskEntities(people: {'ravi': 'money_owed_to_me'});
      expect(AskEntities.find('travis came over', entities.people.keys), isNull);
      expect(AskEntities.find('did ravi pay', entities.people.keys), 'ravi');
    });

    test('the longest matching name wins', () {
      const names = {'bank', 'indian bank'};
      expect(AskEntities.find('what is in indian bank', names), 'indian bank');
    });
  });
}
