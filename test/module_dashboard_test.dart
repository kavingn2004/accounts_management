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
}
