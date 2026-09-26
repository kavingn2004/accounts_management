import 'package:accounts_app/features/common/module_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(E2E.installSecureStorageMock);

  testWidgets('savings page shows the dashboard header', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Target'), findsOneWidget);
    // Seeded goals: 120000 + 30000 + 42000.
    expect(find.text('₹1,92,000'), findsOneWidget);
  });

  testWidgets('an empty ledger shows the no-history copy, not a zero line',
      (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');
    expect(find.text('No history yet'), findsOneWidget);
  });

  testWidgets('the header collapses and re-expands', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    expect(find.text('No history yet'), findsOneWidget);
    await t.tap(find.byIcon(Icons.expand_less));
    await t.pumpAndSettle();

    // Figures survive the collapse; the chart does not.
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('No history yet'), findsNothing);

    await t.tap(find.byIcon(Icons.expand_more));
    await t.pumpAndSettle();
    expect(find.text('No history yet'), findsOneWidget);
  });

  testWidgets("range chips do not filter a balance module's list", (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    // The goal name appears twice — once in the breakdown bars, once in the
    // list row — so count rather than assert a single match.
    final before = t.widgetList(find.text('Emergency fund')).length;
    expect(before, greaterThan(0));

    await t.tap(find.text('Today'));
    await t.pumpAndSettle();

    // Savings goals carry no date column — the list must be unaffected.
    expect(t.widgetList(find.text('Emergency fund')).length, before);
  });

  testWidgets('every module page renders a dashboard header', (t) async {
    await E2E.launch(t);
    for (final page in [
      'Income',
      'Expenses',
      'Savings',
      'Investment',
      'Debtors',
      'Creditors',
      'Bill Payment',
      'Loan',
      'Transfers',
    ]) {
      await E2E.openDrawerItem(t, page);
      expect(find.byType(ModuleDashboard), findsOneWidget,
          reason: '$page has no dashboard header');
      // Module pages are pushed routes with no drawer of their own, so return
      // to the shell before reaching for the drawer again.
      await t.pageBack();
      await t.pumpAndSettle();
    }
  });

  testWidgets('investment shows return on capital', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Investment');
    // Seeded: invested 75000, current value 85300.
    expect(find.text('Return'), findsOneWidget);
    expect(find.text('+13.7%'), findsOneWidget);
  });

  testWidgets('debtors report what has actually been received', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Debtors');

    // Seeded: Meera part-paid 8,000 of 20,000 and Suresh settled 3,500 into
    // an account. Neither has a ledger entry — the figure must still agree
    // with the rows rather than reporting zero beside them.
    expect(find.text('Received'), findsOneWidget);
    expect(find.text('₹11,500'), findsOneWidget);
  });

  testWidgets('loans report principal cleared, closed loans included',
      (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Loan');

    // 500,000 → 320,000 outstanding, plus an 80,000 loan fully repaid.
    expect(find.text('₹2,60,000'), findsOneWidget);
  });
}
