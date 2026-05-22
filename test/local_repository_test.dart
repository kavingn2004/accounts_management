import 'package:accounts_app/data/local_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<LocalRepository> _repo() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return LocalRepository(LocalStore(prefs));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('insert / list / update / delete round-trip', () async {
    final repo = await _repo();

    await repo.insert('income', {'amount': 100, 'source': 'X', 'date': '2026-05-01'});
    var rows = await repo.list('income');
    expect(rows.length, 1);
    final id = rows.first['id'].toString();

    await repo.update('income', id, {'amount': 250});
    rows = await repo.list('income');
    expect(rows.first['amount'], 250);

    await repo.delete('income', id);
    expect(await repo.list('income'), isEmpty);
  });

  test('dashboard computes net worth and month totals', () async {
    final repo = await _repo();
    await repo.insert('income', {'amount': 200});
    await repo.insert('expenses', {'amount': 50});
    await repo.insert('loans', {'outstanding': 30, 'status': 'active'});

    final d = await repo.dashboard();
    expect(d!['month_income'], 200);
    expect(d['month_expense'], 50);
    // accounts(200-50) - loans(30) = 120
    expect(d['net_worth'], 120);
  });

  test('seedIfNeeded seeds once only', () async {
    final repo = await _repo();
    await repo.seedIfNeeded();
    final n = (await repo.list('income')).length;
    expect(n, greaterThan(0));
    await repo.seedIfNeeded(); // must not double-seed
    expect((await repo.list('income')).length, n);
  });

  test('account balances reconcile income/expense/transfer/cash-move', () async {
    final repo = await _repo();
    await repo.insert('accounts', {'name': 'Cash', 'type': 'cash', 'opening_balance': 1000});
    await repo.insert('accounts', {'name': 'Bank', 'type': 'bank', 'opening_balance': 5000});
    await repo.insert('income', {'amount': 2000, 'account': 'Bank'});
    await repo.insert('expenses', {'amount': 300, 'account': 'Cash'});
    await repo.insert('transfers', {'from': 'Bank', 'to': 'Cash', 'amount': 500});
    await repo.insert('cash_moves', {'account': 'Cash', 'amount': -200}); // a payment out

    final accts = await repo.accountsWithBalances();
    double bal(String n) =>
        (accts.firstWhere((a) => a['name'] == n)['balance'] as num).toDouble();

    // Cash: 1000 - 300 + 500 - 200 = 1000
    expect(bal('Cash'), 1000);
    // Bank: 5000 + 2000 - 500 = 6500
    expect(bal('Bank'), 6500);
  });

  test('transactions to an unknown account do not affect any balance', () async {
    final repo = await _repo();
    await repo.insert('accounts', {'name': 'Cash', 'type': 'cash', 'opening_balance': 100});
    await repo.insert('expenses', {'amount': 50, 'account': 'Ghost'});
    final accts = await repo.accountsWithBalances();
    expect((accts.single['balance'] as num).toDouble(), 100);
  });

  test('data persists across repository instances (same store)', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);

    await LocalRepository(store).insert('bills', {'name': 'Rent', 'amount': 100});
    final reopened = LocalRepository(store);
    final rows = await reopened.list('bills');
    expect(rows.single['name'], 'Rent');
  });
}
