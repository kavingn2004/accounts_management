import 'package:accounts_app/features/alerts/alert_engine.dart';
import 'package:accounts_app/features/alerts/alert_model.dart';
import 'package:flutter_test/flutter_test.dart';

List<AppAlert> _gen({
  List<Map<String, dynamic>> bills = const [],
  List<Map<String, dynamic>> loans = const [],
  List<Map<String, dynamic>> goals = const [],
  List<Map<String, dynamic>> debtors = const [],
  List<Map<String, dynamic>> creditors = const [],
  List<Map<String, dynamic>> expenses = const [],
  List<Map<String, dynamic>> income = const [],
  double budget = 0,
}) =>
    AlertEngine.generate(
      bills: bills,
      loans: loans,
      goals: goals,
      debtors: debtors,
      creditors: creditors,
      expenses: expenses,
      income: income,
      monthlyBudget: budget,
      now: DateTime(2026, 5, 22),
    );

void main() {
  test('overdue bill → critical', () {
    final a = _gen(bills: [
      {'id': 'b', 'name': 'Rent', 'amount': 18000, 'due_day': 1, 'status': 'due'}
    ]);
    expect(
        a.any((x) =>
            x.title.contains('Rent') && x.severity == AlertSeverity.critical),
        isTrue);
  });

  test('paid bill → no alert', () {
    final a = _gen(bills: [
      {'id': 'b', 'name': 'Rent', 'amount': 18000, 'due_day': 1, 'status': 'paid'}
    ]);
    expect(a, isEmpty);
  });

  test('over budget → critical', () {
    final a = _gen(
      expenses: [
        {'amount': 12000, 'date': '2026-05-10', 'payee': 'X'}
      ],
      budget: 10000,
    );
    expect(
        a.any((x) => x.key == 'budget' && x.severity == AlertSeverity.critical),
        isTrue);
  });

  test('savings milestone at 50%', () {
    final a = _gen(goals: [
      {'id': 'g', 'name': 'Fund', 'target_amount': 100, 'saved_amount': 60}
    ]);
    expect(a.any((x) => x.title.contains('Fund')), isTrue);
  });

  test('active loan accrues interest alert; closed loan ignored', () {
    final a = _gen(loans: [
      {'id': 'l1', 'lender': 'HDFC', 'emi': 11000, 'outstanding': 320000, 'interest_rate': 9.5, 'status': 'active'},
      {'id': 'l2', 'lender': 'Bajaj', 'emi': 7000, 'outstanding': 0, 'interest_rate': 14, 'status': 'closed'},
    ]);
    expect(a.any((x) => x.title.contains('HDFC')), isTrue);
    expect(a.any((x) => x.title.contains('Bajaj')), isFalse);
  });

  test('debtor due within lead → warning', () {
    final a = _gen(debtors: [
      {'id': 'd', 'person_name': 'Ravi', 'amount': 5000, 'due_date': '2026-05-24', 'status': 'open'}
    ]);
    expect(
        a.any((x) =>
            x.title.contains('Ravi') && x.severity == AlertSeverity.warning),
        isTrue);
  });

  test('alerts sorted critical first', () {
    final a = _gen(
      bills: [
        {'id': 'b', 'name': 'Rent', 'amount': 1, 'due_day': 1, 'status': 'due'}
      ],
      goals: [
        {'id': 'g', 'name': 'Fund', 'target_amount': 100, 'saved_amount': 60}
      ],
    );
    expect(a.first.severity, AlertSeverity.critical);
  });
}
