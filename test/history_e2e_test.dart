import 'package:accounts_app/features/common/entity_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(E2E.installSecureStorageMock);

  testWidgets('an added expense shows in History and Undo removes it',
      (t) async {
    await E2E.launch(t);
    final before = E2E.lastStore!.read('expenses').length;

    await E2E.openDrawerItem(t, 'Expenses');
    await t.tap(find.byType(FloatingActionButton));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Amount'), '777');
    await t.enterText(find.widgetWithText(TextField, 'Payee'), 'Taxi');
    await E2E.tapVisible(t, find.text('Select date'));
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    await E2E.tapVisible(t, find.text('Save expenses'));
    expect(E2E.lastStore!.read('expenses').length, before + 1);

    await t.pageBack();
    await t.pumpAndSettle();
    await E2E.openDrawerItem(t, 'History');
    expect(find.textContaining('Added Expenses · Taxi'), findsOneWidget);

    await t.tap(find.widgetWithText(TextButton, 'Undo'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Undo'));
    await t.pumpAndSettle();

    final rows = E2E.lastStore!.read('expenses');
    expect(rows.length, before);
    expect(rows.any((r) => r['payee'] == 'Taxi'), isFalse);
    expect(find.text('Undone'), findsOneWidget);
  });

  test('date-ordered lists put the latest date first', () {
    final sorted = sortRowsByDateDesc([
      {'id': 'a', 'date': '2026-09-01', 'created_at': '2026-09-20T10:00:00'},
      {'id': 'b', 'date': '2026-09-15', 'created_at': '2026-09-02T10:00:00'},
      {'id': 'c'},
      {'id': 'd', 'date': '2026-09-15', 'created_at': '2026-09-10T10:00:00'},
      {'id': 'e', 'date': '2026-08-30'},
    ]);
    expect(sorted.map((r) => r['id']), ['d', 'b', 'a', 'e', 'c']);
  });
}
