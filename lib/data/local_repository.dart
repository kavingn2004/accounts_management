import 'finance_repository.dart';
import 'local_store.dart';

/// On-device implementation of [FinanceRepository]. All reads/writes go through
/// [LocalStore] (shared_preferences). Seeds sample data on first run.
class LocalRepository extends FinanceRepository {
  LocalRepository(this._store);
  final LocalStore _store;

  int _seq = 0;
  String _id() =>
      'l${DateTime.now().microsecondsSinceEpoch}${_seq++}';

  @override
  Future<List<Json>> list(
    String table, {
    String orderBy = 'created_at',
    bool ascending = false,
  }) async =>
      _store.read(table);

  @override
  Future<void> insert(String table, Json values) async {
    final rows = _store.read(table);
    rows.insert(0, {...values, 'id': _id()});
    await _store.write(table, rows);
  }

  @override
  Future<void> update(String table, String id, Json values) async {
    final rows = _store.read(table);
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) {
      rows[i] = {...rows[i], ...values};
      await _store.write(table, rows);
    }
  }

  @override
  Future<void> delete(String table, String id) async {
    final rows = _store.read(table)
      ..removeWhere((r) => r['id'].toString() == id);
    await _store.write(table, rows);
  }

  /// Live balance per account name: opening balance + every cash movement that
  /// references the account (income +, expense −, transfers, payment moves).
  /// Single source of truth for both the accounts list and net worth.
  Map<String, double> _balanceMap() {
    final accounts = _store.read('accounts');
    final balances = <String, double>{
      for (final a in accounts)
        (a['name'] ?? '').toString():
            (a['opening_balance'] as num?)?.toDouble() ?? 0,
    };

    void add(String? name, double delta) {
      if (name != null && balances.containsKey(name)) {
        balances[name] = balances[name]! + delta;
      }
    }

    double amt(Json r, [String k = 'amount']) =>
        (r[k] as num?)?.toDouble() ?? 0;

    for (final r in _store.read('income')) {
      add(r['account']?.toString(), amt(r));
    }
    for (final r in _store.read('expenses')) {
      add(r['account']?.toString(), -amt(r));
    }
    for (final t in _store.read('transfers')) {
      add(t['from']?.toString(), -amt(t));
      add(t['to']?.toString(), amt(t));
    }
    // Signed payment movements (negative = money out, positive = money in).
    for (final m in _store.read('cash_moves')) {
      add(m['account']?.toString(), amt(m));
    }
    return balances;
  }

  @override
  Future<List<Json>> accountsWithBalances() async {
    final balances = _balanceMap();
    return _store
        .read('accounts')
        .map((a) =>
            {...a, 'balance': balances[(a['name'] ?? '').toString()] ?? 0})
        .toList();
  }

  @override
  Future<Json?> dashboard() async {
    double sum(String table, String key) => _store
        .read(table)
        .fold(0.0, (a, r) => a + ((r[key] as num?)?.toDouble() ?? 0));

    // Cash/bank component = sum of account balances (includes opening balances
    // plus every income/expense/transfer tied to an account).
    final accountsTotal = _balanceMap().values.fold(0.0, (a, b) => a + b);
    final investments = sum('investments', 'current_value');
    final savings = sum('savings_goals', 'saved_amount');
    final receivable = sum('debtors', 'amount');
    final payable = sum('creditors', 'amount');
    final loans = _store
        .read('loans')
        .where((r) => r['status'] == 'active')
        .fold(0.0, (a, r) => a + ((r['outstanding'] as num?)?.toDouble() ?? 0));

    return {
      'net_worth':
          accountsTotal + investments + savings + receivable - payable - loans,
      'month_income': sum('income', 'amount'),
      'month_expense': sum('expenses', 'amount'),
    };
  }

  /// Populate sample data the first time the app runs.
  Future<void> seedIfNeeded() async {
    if (_store.isSeeded) return;

    String days(int agoDays) {
      final dt = DateTime.now().subtract(Duration(days: agoDays));
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      return '${dt.year}-$m-$d';
    }

    await _store.write('accounts', [
      {'id': _id(), 'name': 'Cash', 'type': 'cash', 'opening_balance': 5000},
      {'id': _id(), 'name': 'HDFC Bank', 'type': 'bank', 'opening_balance': 50000},
    ]);
    await _store.write('transfers', []);
    await _store.write('cash_moves', []);

    await _store.write('income', [
      {'id': _id(), 'source': 'Salary', 'amount': 65000, 'date': days(21), 'account': 'HDFC Bank', 'note': 'Monthly pay'},
      {'id': _id(), 'source': 'Freelance', 'amount': 12000, 'date': days(4), 'account': 'HDFC Bank', 'note': 'Logo design'},
      {'id': _id(), 'source': 'Bonus', 'amount': 8000, 'date': days(95), 'account': 'HDFC Bank', 'note': 'Quarterly'},
    ]);
    await _store.write('expenses', [
      {'id': _id(), 'payee': 'Groceries', 'amount': 4800, 'date': days(2), 'account': 'Cash', 'note': 'BigBasket'},
      {'id': _id(), 'payee': 'Dining', 'amount': 1500, 'date': days(1), 'account': 'Cash', 'note': 'Dinner out'},
      {'id': _id(), 'payee': 'Electricity', 'amount': 1900, 'date': days(3), 'account': 'HDFC Bank', 'note': 'Monthly bill'},
      {'id': _id(), 'payee': 'Fuel', 'amount': 3000, 'date': days(6), 'account': 'Cash', 'note': ''},
      {'id': _id(), 'payee': 'Shopping', 'amount': 6000, 'date': days(40), 'account': 'HDFC Bank', 'note': 'Clothes'},
      {'id': _id(), 'payee': 'Insurance', 'amount': 2500, 'date': days(120), 'account': 'HDFC Bank', 'note': 'Premium'},
    ]);
    await _store.write('savings_goals', [
      {'id': _id(), 'name': 'Emergency fund', 'target_amount': 200000, 'saved_amount': 120000, 'target_date': '2026-12-31'},
      {'id': _id(), 'name': 'New laptop', 'target_amount': 90000, 'saved_amount': 30000, 'target_date': '2026-09-30'},
    ]);
    await _store.write('investments', [
      {'id': _id(), 'name': 'Nifty 50 Index', 'type': 'fund', 'invested_amount': 50000, 'current_value': 58200},
      {'id': _id(), 'name': 'Gold ETF', 'type': 'gold', 'invested_amount': 25000, 'current_value': 27100},
    ]);
    await _store.write('debtors', [
      {'id': _id(), 'person_name': 'Ravi', 'contact': '98xxxxxx01', 'amount': 5000, 'due_date': days(-2), 'status': 'open', 'note': 'Lunch + cab'},
    ]);
    await _store.write('creditors', [
      {'id': _id(), 'person_name': 'Anita', 'contact': '98xxxxxx02', 'amount': 8000, 'due_date': days(-4), 'status': 'partial', 'note': 'Borrowed for trip'},
    ]);
    await _store.write('bills', [
      {'id': _id(), 'name': 'Internet', 'amount': 1200, 'due_day': 5, 'frequency': 'monthly', 'status': 'paid'},
      {'id': _id(), 'name': 'Rent', 'amount': 18000, 'due_day': 1, 'frequency': 'monthly', 'status': 'due'},
    ]);
    await _store.write('loans', [
      {'id': _id(), 'lender': 'HDFC Bank', 'principal': 500000, 'outstanding': 320000, 'interest_rate': 9.5, 'emi': 11000, 'start_date': days(700), 'status': 'active', 'note': 'Car loan'},
      {'id': _id(), 'lender': 'Bajaj Finserv', 'principal': 80000, 'outstanding': 0, 'interest_rate': 14, 'emi': 7000, 'start_date': days(400), 'status': 'closed', 'note': 'Phone EMI'},
    ]);
    await _store.write('alerts', [
      {'id': _id(), 'title': 'Review monthly budget', 'message': 'Check category spending before month end.', 'severity': 'info', 'type': 'custom'},
    ]);

    await _store.markSeeded();
  }
}
