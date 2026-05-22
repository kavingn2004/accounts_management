import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(E2E.installSecureStorageMock);

  testWidgets('dashboard shows the Balances card with seeded accounts',
      (tester) async {
    await E2E.launch(tester);
    expect(find.text('Balances'), findsOneWidget);
    expect(find.text('Cash'), findsWidgets);
    expect(find.text('HDFC Bank'), findsWidgets);
  });

  testWidgets('Accounts screen: add a bank → appears in the list',
      (tester) async {
    await E2E.launch(tester);
    await E2E.openDrawerItem(tester, 'Accounts');

    expect(find.text('Total balance'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add Bank'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add Bank'));
    await tester.pumpAndSettle();

    // Dialog: name field (0), opening balance field (1).
    await tester.enterText(find.byType(TextField).at(0), 'SBI');
    await tester.enterText(find.byType(TextField).at(1), '20000');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('SBI'), findsOneWidget);
  });

  testWidgets('Income form exposes an Account dropdown with the seeded banks',
      (tester) async {
    await E2E.launch(tester);
    await E2E.openDrawerItem(tester, 'Income');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Account (optional)'), findsOneWidget);

    // Open the dropdown and confirm a seeded account is offered.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('HDFC Bank'), findsWidgets);
  });

  testWidgets('Transfers form has From/To account fields', (tester) async {
    await E2E.launch(tester);
    await E2E.openDrawerItem(tester, 'Transfers');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('From account'), findsOneWidget);
    expect(find.text('To account'), findsOneWidget);
  });
}
