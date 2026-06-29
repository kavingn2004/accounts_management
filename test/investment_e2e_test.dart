import 'package:accounts_app/core/formatters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// End-to-end coverage for the investment module changes:
/// new FD/MF/SIP types, the optional "paid from account" deduction, the
/// auto-maintained total-invested column, and the "Update current value" /
/// "Add investment" row actions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(E2E.installSecureStorageMock);

  testWidgets('investment list shows seeded holdings with total invested',
      (tester) async {
    await E2E.launch(tester);
    await E2E.openDrawerItem(tester, 'Investment');

    expect(find.text('Nifty 50 Index'), findsOneWidget);
    expect(find.text('Gold ETF'), findsOneWidget);
    // Each row subtitle reports the running total invested.
    expect(find.textContaining('total invested'), findsWidgets);
  });

  testWidgets('add form offers MF/SIP types and a paid-from-account picker',
      (tester) async {
    await E2E.launch(tester);
    await E2E.openDrawerItem(tester, 'Investment');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Optional account picker is present on the create form.
    expect(find.text('Paid from account (optional)'), findsOneWidget);

    // The Type dropdown (first dropdown on the form) offers the new options.
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('mf'), findsWidgets);
    expect(find.text('sip'), findsWidgets);
    expect(find.text('fd'), findsWidgets);
  });

  testWidgets(
      'create paid-from-account → deducts cash & seeds total; '
      'update + add adjust it', (tester) async {
    await E2E.launch(tester);
    await E2E.openDrawerItem(tester, 'Investment');

    // --- Create an investment paid from the seeded "Cash" account. ---
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final textFields = find.byType(TextFormField); // Name, Invested, Current
    await tester.enterText(textFields.at(0), 'Test SIP');
    await tester.enterText(textFields.at(1), '30000');
    await tester.enterText(textFields.at(2), '31000');
    await tester.pump();

    // Paid-from picker is the last dropdown; choose "Cash".
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Test SIP'), findsOneWidget);

    // Persisted: total_invested seeded from invested; cash deducted by 30000.
    final store = E2E.lastStore!;
    final created = store.read('investments').firstWhere(
          (r) => r['name'] == 'Test SIP',
        );
    expect((created['invested_amount'] as num), 30000);
    expect((created['total_invested'] as num), 30000);
    expect(
      store.read('cash_moves').any(
            (m) => m['account'] == 'Cash' && (m['amount'] as num) == -30000,
          ),
      isTrue,
      reason: 'invested amount should be recorded as money out of Cash',
    );

    // The new row is inserted at the top, so it is the first row.
    // --- Update its current value (overwrite). ---
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update current value'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '99999');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text(money(99999)), findsWidgets);
    expect(
      store.read('investments').firstWhere((r) => r['name'] == 'Test SIP')[
          'current_value'] as num,
      99999,
    );

    // --- Add to the investment (grows invested, total, and current value). ---
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add investment'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '5000');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final after =
        store.read('investments').firstWhere((r) => r['name'] == 'Test SIP');
    expect((after['invested_amount'] as num), 35000); // 30000 + 5000
    expect((after['total_invested'] as num), 35000); // 30000 + 5000
    expect((after['current_value'] as num), 104999); // 99999 + 5000
  });

  testWidgets('dashboard reflects a new investment in worth + invested cards',
      (tester) async {
    await E2E.launch(tester);

    // Baseline seeded totals: worth 85300, invested 75000.
    final dashScroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.text('Investment worth'), 150, scrollable: dashScroll);
    await tester.pumpAndSettle();
    expect(find.text(money(85300)), findsOneWidget);
    expect(find.text(money(75000)), findsOneWidget);

    // Add an investment (invested 10000, current 12000), no account.
    await E2E.openDrawerItem(tester, 'Investment');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Extra Fund');
    await tester.enterText(fields.at(1), '10000');
    await tester.enterText(fields.at(2), '12000');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Back to the dashboard; totals should grow by the new holding.
    await tester.pageBack();
    await tester.pumpAndSettle();

    final dashScroll2 = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.text('Investment worth'), 150, scrollable: dashScroll2);
    await tester.pumpAndSettle();
    expect(find.text(money(85300 + 12000)), findsOneWidget); // worth
    expect(find.text(money(75000 + 10000)), findsOneWidget); // invested
  });
}
