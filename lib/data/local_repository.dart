import 'finance_math.dart';
import 'finance_repository.dart';
import 'local_store.dart';

/// On-device implementation of [FinanceRepository]. All reads/writes go through
/// [LocalStore] (shared_preferences). Seeds sample data on first run.
class LocalRepository extends FinanceRepository
    implements UndoableRepository {
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
  Future<void> insert(String table, Json values) =>
      insertReturningId(table, values);

  @override
  Future<String> insertReturningId(String table, Json values) async {
    final id = _id();
    final rows = _store.read(table);
    // Stamp the creation time the way Supabase does. The dashboard's stock
    // trends need it to tell a debt that existed at the start of the period
    // from one taken on since; rows written before this stamp have none and
    // are treated as pre-existing.
    rows.insert(0, {
      'created_at': DateTime.now().toIso8601String(),
      ...values,
      'id': id,
    });
    await _store.write(table, rows);
    return id;
  }

  @override
  Future<void> restore(String table, Json row) async {
    final rows = _store.read(table);
    final id = row['id'].toString();
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) {
      rows[i] = Json.from(row);
    } else {
      // Rows are kept newest first; slot the row back where its creation time
      // puts it, so it doesn't jump to the top of every list. Rows with no
      // stamp are the oldest (see [insert]).
      final at = row['created_at']?.toString();
      var pos = rows.length;
      if (at != null) {
        final j = rows.indexWhere((r) {
          final c = r['created_at']?.toString();
          return c == null || c.compareTo(at) < 0;
        });
        if (j >= 0) pos = j;
      }
      rows.insert(pos, Json.from(row));
    }
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

  /// Single source of truth for account balances (see [FinanceMath.balanceMap]).
  Map<String, double> _balanceMap() => FinanceMath.balanceMap(
        accounts: _store.read('accounts'),
        income: _store.read('income'),
        expenses: _store.read('expenses'),
        transfers: _store.read('transfers'),
        cashMoves: _store.read('cash_moves'),
      );

  @override
  Future<List<Json>> accountsWithBalances() async =>
      FinanceMath.accountsWithBalances(
        accounts: _store.read('accounts'),
        balances: _balanceMap(),
      );

  @override
  Future<Json?> dashboard() async => FinanceMath.dashboard(
        balances: _balanceMap(),
        income: _store.read('income'),
        expenses: _store.read('expenses'),
        investments: _store.read('investments'),
        savingsGoals: _store.read('savings_goals'),
        debtors: _store.read('debtors'),
        creditors: _store.read('creditors'),
        loans: _store.read('loans'),
        bills: _store.read('bills'),
      );

  /// Populate sample data the first time the app runs.
  Future<void> seedIfNeeded() async {
    if (_store.isSeeded) return;

    String days(int agoDays) {
      final dt = DateTime.now().subtract(Duration(days: agoDays));
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      return '${dt.year}-$m-$d';
    }

    /// A date guaranteed to fall inside the *current* calendar month, on or
    /// before today. `days()` alone can't promise that — seed the app on the
    /// 2nd and half its rows land in the previous month, leaving the default
    /// Month view looking empty.
    String thisMonth(int day) {
      final now = DateTime.now();
      final d = day.clamp(1, now.day);
      final m = now.month.toString().padLeft(2, '0');
      return '${now.year}-$m-${d.toString().padLeft(2, '0')}';
    }

    await _store.write('accounts', [
      {'id': _id(), 'name': 'Cash', 'type': 'cash', 'opening_balance': 5000},
      {'id': _id(), 'name': 'HDFC Bank', 'type': 'bank', 'opening_balance': 50000},
    ]);
    await _store.write('transfers', []);
    await _store.write('cash_moves', []);
    // The per-row value ledger starts empty — seeded rows get no invented
    // history, so their charts show "no history yet" until real edits land.
    await _store.write('module_events', []);

    await _store.write('income', [
      {'id': _id(), 'source': 'Salary', 'amount': 65000, 'date': days(21), 'account': 'HDFC Bank', 'note': 'Monthly pay'},
      {'id': _id(), 'source': 'Freelance', 'amount': 12000, 'date': days(4), 'account': 'HDFC Bank', 'note': 'Logo design'},
      {'id': _id(), 'source': 'Bonus', 'amount': 8000, 'date': days(95), 'account': 'HDFC Bank', 'note': 'Quarterly'},
      {'id': _id(), 'source': 'Rent received', 'amount': 15000, 'date': thisMonth(3), 'account': 'HDFC Bank', 'note': 'Tenant — 2BHK'},
      {'id': _id(), 'source': 'Dividends', 'amount': 3400, 'date': thisMonth(11), 'account': 'HDFC Bank', 'note': 'Nifty 50 payout'},
      {'id': _id(), 'source': 'Interest', 'amount': 1250, 'date': thisMonth(20), 'account': 'HDFC Bank', 'note': 'Savings interest'},
    ]);
    // Enough distinct payees inside the current month that the dashboard's
    // expense breakdown fills its five rows and offers "See more".
    await _store.write('expenses', [
      {'id': _id(), 'payee': 'Rent', 'amount': 18000, 'date': thisMonth(1), 'account': 'HDFC Bank', 'note': 'Landlord'},
      {'id': _id(), 'payee': 'School fees', 'amount': 12500, 'date': thisMonth(8), 'account': 'HDFC Bank', 'note': 'Term 2'},
      {'id': _id(), 'payee': 'Groceries', 'amount': 4800, 'date': thisMonth(2), 'account': 'Cash', 'note': 'BigBasket'},
      {'id': _id(), 'payee': 'Fuel', 'amount': 3000, 'date': thisMonth(6), 'account': 'Cash', 'note': ''},
      {'id': _id(), 'payee': 'Electricity', 'amount': 1900, 'date': thisMonth(5), 'account': 'HDFC Bank', 'note': 'Monthly bill'},
      {'id': _id(), 'payee': 'Dining', 'amount': 1500, 'date': thisMonth(14), 'account': 'Cash', 'note': 'Dinner out'},
      {'id': _id(), 'payee': 'Medicines', 'amount': 1450.75, 'date': thisMonth(9), 'account': 'Cash', 'note': 'Pharmacy'},
      {'id': _id(), 'payee': 'Internet', 'amount': 1199, 'date': thisMonth(12), 'account': 'HDFC Bank', 'note': 'Fibre plan'},
      {'id': _id(), 'payee': 'Phone recharge', 'amount': 799, 'date': thisMonth(16), 'account': 'Cash', 'note': ''},
      {'id': _id(), 'payee': 'Gym', 'amount': 700, 'date': thisMonth(4), 'account': 'Cash', 'note': 'Monthly'},
      // Older rows so the Year and All ranges differ from Month.
      {'id': _id(), 'payee': 'Shopping', 'amount': 6000, 'date': days(40), 'account': 'HDFC Bank', 'note': 'Clothes'},
      {'id': _id(), 'payee': 'Insurance', 'amount': 2500, 'date': days(120), 'account': 'HDFC Bank', 'note': 'Premium'},
    ]);
    await _store.write('savings_goals', [
      {'id': _id(), 'name': 'Emergency fund', 'target_amount': 200000, 'saved_amount': 120000, 'target_date': '2026-12-31'},
      {'id': _id(), 'name': 'New laptop', 'target_amount': 90000, 'saved_amount': 30000, 'target_date': '2026-09-30'},
      {'id': _id(), 'name': 'Trip to Japan', 'target_amount': 350000, 'saved_amount': 42000, 'target_date': '2027-04-30'},
    ]);
    await _store.write('investments', [
      {'id': _id(), 'name': 'Nifty 50 Index', 'type': 'fund', 'invested_amount': 50000, 'current_value': 58200},
      {'id': _id(), 'name': 'Gold ETF', 'type': 'gold', 'invested_amount': 25000, 'current_value': 27100},
    ]);
    await _store.write('debtors', [
      {'id': _id(), 'person_name': 'Ravi', 'contact': '98xxxxxx01', 'amount': 5000, 'due_date': days(-2), 'status': 'open', 'note': 'Lunch + cab'},
      {'id': _id(), 'person_name': 'Meera', 'contact': '98xxxxxx03', 'amount': 12000, 'original_amount': 20000, 'due_date': days(-9), 'status': 'partial', 'note': 'Bike repair loan'},
      {'id': _id(), 'person_name': 'Suresh', 'contact': '98xxxxxx04', 'amount': 0, 'original_amount': 3500, 'due_date': days(12), 'status': 'settled', 'settled_account': 'Cash', 'note': 'Paid back in full'},
    ]);
    await _store.write('creditors', [
      {'id': _id(), 'person_name': 'Anita', 'contact': '98xxxxxx02', 'amount': 8000, 'due_date': days(-4), 'status': 'partial', 'note': 'Borrowed for trip'},
      {'id': _id(), 'person_name': 'Karthik', 'contact': '98xxxxxx05', 'amount': 25000, 'original_amount': 25000, 'due_date': days(-21), 'status': 'open', 'note': 'Laptop advance'},
    ]);
    await _store.write('bills', [
      {'id': _id(), 'name': 'Internet', 'amount': 1200, 'due_day': 5, 'frequency': 'monthly', 'status': 'paid'},
      {'id': _id(), 'name': 'Rent', 'amount': 18000, 'due_day': 1, 'frequency': 'monthly', 'status': 'due'},
      {'id': _id(), 'name': 'Mobile postpaid', 'amount': 799, 'due_day': 18, 'frequency': 'monthly', 'status': 'due'},
      {'id': _id(), 'name': 'Car insurance', 'amount': 14500, 'due_day': 22, 'frequency': 'yearly', 'status': 'due'},
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
