import 'finance_repository.dart';

/// What one investment row is worth.
///
/// `current_value` when a figure has been stated — typed in, or written by the
/// live-price sync. Otherwise **what the holding cost**, because a row with no
/// stated value is not a row worth nothing. Two ways that legitimately happens:
///
///  - the row was added with only an invested amount (the field is optional);
///  - a SIP was created today and the fund has not published a NAV to allot
///    at yet, so it holds no units even though the money has left the account.
///
/// Reading zero in either case understates the portfolio by the entire cost of
/// the holding, on the row and in net worth alike. A deliberate zero is left
/// alone: a written-off holding is worth zero and must stay so.
double investmentValue(Json row) {
  final stated = row['current_value'];
  if (stated is num) return stated.toDouble();
  final cost = row['total_invested'] ?? row['invested_amount'];
  return cost is num ? cost.toDouble() : 0;
}

/// Pure balance & dashboard computations shared by every [FinanceRepository]
/// implementation, so on-device and Supabase storage produce identical numbers.
///
/// Each function takes already-fetched table rows (the same shape the app uses)
/// and returns derived values — no I/O here.
class FinanceMath {
  const FinanceMath._();

  static double _amt(Json r, [String k = 'amount']) =>
      (r[k] as num?)?.toDouble() ?? 0;

  /// Live balance per account name: opening balance + every cash movement that
  /// references the account (income +, expense −, transfers, payment moves).
  /// Single source of truth for both the accounts list and net worth.
  static Map<String, double> balanceMap({
    required List<Json> accounts,
    required List<Json> income,
    required List<Json> expenses,
    required List<Json> transfers,
    required List<Json> cashMoves,
  }) {
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

    for (final r in income) {
      add(r['account']?.toString(), _amt(r));
    }
    for (final r in expenses) {
      add(r['account']?.toString(), -_amt(r));
    }
    for (final t in transfers) {
      add(t['from']?.toString(), -_amt(t));
      add(t['to']?.toString(), _amt(t));
    }
    // Signed payment movements (negative = money out, positive = money in).
    for (final m in cashMoves) {
      add(m['account']?.toString(), _amt(m));
    }
    return balances;
  }

  /// Accounts with a computed 'balance' key added to each row.
  static List<Json> accountsWithBalances({
    required List<Json> accounts,
    required Map<String, double> balances,
  }) =>
      accounts
          .map((a) =>
              {...a, 'balance': balances[(a['name'] ?? '').toString()] ?? 0})
          .toList();

  /// Single-row dashboard snapshot: net worth + this-period income/expense.
  static Json dashboard({
    required Map<String, double> balances,
    required List<Json> income,
    required List<Json> expenses,
    required List<Json> investments,
    required List<Json> savingsGoals,
    required List<Json> debtors,
    required List<Json> creditors,
    required List<Json> loans,
    required List<Json> bills,
  }) {
    double sum(List<Json> rows, String key) =>
        rows.fold(0.0, (a, r) => a + ((r[key] as num?)?.toDouble() ?? 0));

    // Settled debts are closed out — exclude them from what's owed.
    double sumOwed(List<Json> rows) => rows
        .where((r) => r['status'] != 'settled')
        .fold(0.0, (a, r) => a + ((r['amount'] as num?)?.toDouble() ?? 0));

    final accountsTotal = balances.values.fold(0.0, (a, b) => a + b);
    final investmentsTotal =
        investments.fold(0.0, (a, r) => a + investmentValue(r));
    // `total_invested` is the running sum of every contribution (see the
    // investment module's cumulativeIncrementField). Rows created before that
    // column existed fall back to `invested_amount`, which held the same figure.
    final investedTotal = investments.fold(
        0.0,
        (a, r) =>
            a +
            (((r['total_invested'] ?? r['invested_amount']) as num?)
                    ?.toDouble() ??
                0));
    final savings = sum(savingsGoals, 'saved_amount');
    final savingsTarget = sum(savingsGoals, 'target_amount');
    final receivable = sumOwed(debtors);
    final payable = sumOwed(creditors);
    final billsTotal = sum(bills, 'amount');
    final loansTotal = loans
        .where((r) => r['status'] == 'active')
        .fold(0.0, (a, r) => a + ((r['outstanding'] as num?)?.toDouble() ?? 0));

    return {
      'net_worth': accountsTotal +
          investmentsTotal +
          savings +
          receivable -
          payable -
          loansTotal,
      // Worth breakdown shown on the dashboard:
      'current_worth': accountsTotal, // cash + all bank balances
      'debt_worth': receivable, // owed to you (debtors / collections)
      'credit_worth': payable + billsTotal, // you owe (creditors + bills)
      'saving_worth': savings, // savings goals set aside
      'saving_target': savingsTarget, // combined goal targets
      'investment_worth': investmentsTotal, // current value of holdings
      'invested_total': investedTotal, // total amount put in
      'bills_total': billsTotal, // recurring bills folded into credit_worth
      // Subtracted by net_worth above, so anything itemising that figure needs
      // it: without this the parts cannot be made to add up to the whole.
      'loans_total': loansTotal,
      'month_income': sum(income, 'amount'),
      'month_expense': sum(expenses, 'amount'),
    };
  }
}
