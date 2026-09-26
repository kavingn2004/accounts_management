import 'package:accounts_app/data/module_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(E2E.installSecureStorageMock);

  testWidgets('adding to a savings goal records an increment event', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    // The seeded "Emergency fund" goal sits at 120000. Scroll the dashboard
    // header away first: the row's overflow button otherwise sits beneath the
    // floating action button, and the tap lands on the FAB instead.
    await t.drag(find.byType(ListView).last, const Offset(0, -260));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.more_vert).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add to savings'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '5000');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    final events = E2E.lastStore!.read(moduleEventsTable);
    expect(events.length, 1);
    expect(events.single['parent_type'], 'savings_goals');
    expect(events.single['field'], 'saved_amount');
    expect(events.single['kind'], 'increment');
    expect(events.single['amount'], 5000.0);
    expect(events.single['balance_after'], 125000.0);
  });

  testWidgets('creating a goal records an opening event', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Savings');

    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Goal name'), 'Car');
    await t.enterText(
        find.widgetWithText(TextField, 'Target amount'), '400000');
    await t.enterText(find.widgetWithText(TextField, 'Saved so far'), '25000');
    await t.tap(find.text('Save savings'));
    await t.pumpAndSettle();

    final open = E2E.lastStore!
        .read(moduleEventsTable)
        .where((e) => e['kind'] == 'open')
        .toList();
    expect(open.length, 1);
    expect(open.single['balance_after'], 25000.0);
  });

  testWidgets('an investment contribution records both columns', (t) async {
    await E2E.launch(t);
    await E2E.openDrawerItem(t, 'Investment');

    await t.tap(find.byIcon(Icons.more_vert).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add investment'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '10000');
    await t.tap(find.text('Add'));
    await t.pumpAndSettle();

    final events = E2E.lastStore!.read(moduleEventsTable);
    final fields = events.map((e) => e['field']).toSet();
    expect(fields, {'invested_amount', 'current_value'});
  });
}
