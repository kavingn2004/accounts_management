import 'package:accounts_app/core/formatters.dart';
import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/features/investments/sip_screen.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:accounts_app/services/quotes/quote_service.dart';
import 'package:accounts_app/services/sip_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

/// End-to-end journeys through the real app, offline.
///
/// These drive the whole stack the way a person does — boot, unlock, navigate,
/// type, tap — and assert on what was actually persisted. Unit tests prove each
/// piece; these prove the pieces are wired to each other.

/// AMFI stand-in: one searchable fund with a flat NAV of 100, so units are
/// whole numbers and the arithmetic is checkable by eye.
class _FakeNavApi implements NavApi {
  int historyCalls = 0;

  @override
  Future<List<SchemeRef>> search(String query) async => const [
        SchemeRef(
            code: 120503,
            name: 'Tata Large & Mid Cap Fund - Direct Plan - Growth'),
        SchemeRef(
            code: 120504,
            name: 'Tata Large & Mid Cap Fund - Regular Plan - IDCW'),
      ];

  @override
  Future<NavSeries> history(int code) async {
    historyCalls++;
    // Published every day, so an allotment resolves whatever date the test
    // lands on — weekend behaviour has its own unit tests in sip_math_test.
    final navs = <DateTime, double>{};
    var cursor = DateTime(2020, 1, 1);
    final end = DateTime.now().add(const Duration(days: 7));
    while (cursor.isBefore(end)) {
      navs[cursor] = 100;
      cursor = cursor.add(const Duration(days: 1));
    }
    return NavSeries(
      code: code,
      schemeName: 'Tata Large & Mid Cap Fund - Direct Plan - Growth',
      fundHouse: 'Tata Mutual Fund',
      navs: navs,
    );
  }
}

/// Every price lookup answers with a NAV of 100.
QuoteService _quotes() => QuoteService(
      client: MockClient((_) async => http.Response(
          '{"data":[{"date":"01-01-2026","nav":"100.00000"}]}', 200)),
    );

List<Override> _offline(_FakeNavApi api) => [
      navApiProvider.overrideWithValue(api),
      quoteServiceProvider.overrideWithValue(_quotes()),
    ];

/// Type into the form field carrying [label].
Future<void> _fill(WidgetTester tester, String label, String value) async {
  final field = find.ancestor(
    of: find.text(label),
    matching: find.byType(TextFormField),
  );
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> _chooseType(WidgetTester tester, String type) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(type).last);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(E2E.installSecureStorageMock);

  testWidgets('a self-valuing holding: add it, and it prices itself',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeNavApi();
    await E2E.launch(tester, overrides: _offline(api));
    await E2E.openDrawerItem(tester, 'Investment');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await _fill(tester, 'Name', 'Mid Cap');
    await _chooseType(tester, 'mf');
    await _fill(tester, 'Invested', '500');
    await _fill(tester, 'Quantity held', '5');
    await _fill(tester, 'Current market price', '120');

    await E2E.tapVisible(
        tester, find.widgetWithText(FilledButton, 'Save investment'));

    // The row values itself from what was typed: 120 × 5.
    final saved = E2E.lastStore!
        .read('investments')
        .firstWhere((r) => r['name'] == 'Mid Cap');
    expect(saved['current_value'], 600);
    expect(saved['last_price'], 120);
    expect(saved['price_source'], 'Manual price');
    expect(find.text(money(600)), findsWidgets);
  });

  testWidgets('redeeming credits an account and reduces the holding',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeNavApi();
    await E2E.launch(tester, overrides: _offline(api));
    await E2E.openDrawerItem(tester, 'Investment');

    // Build the holding the way a person would.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await _fill(tester, 'Name', 'Nifty Units');
    await _chooseType(tester, 'mf');
    await _fill(tester, 'Invested', '10000');
    await _fill(tester, 'Quantity held', '100');
    await _fill(tester, 'Current market price', '120');
    await E2E.tapVisible(
        tester, find.widgetWithText(FilledButton, 'Save investment'));

    final store = E2E.lastStore!;
    expect(
      store.read('investments').firstWhere(
          (r) => r['name'] == 'Nifty Units')['current_value'],
      12000,
    );

    // Sell a quarter of it. New rows are inserted at the top of the store, so
    // the holding just added owns the first row menu.
    await tester.drag(find.byType(ListView).last, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Redeem').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '25');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Redeem'));
    await tester.pumpAndSettle();

    final after =
        store.read('investments').firstWhere((r) => r['name'] == 'Nifty Units');
    expect(after['quantity'], 75, reason: '100 held less 25 sold');

    // The proceeds landed in an account as money in.
    final credit = store
        .read('cash_moves')
        .firstWhere((m) => (m['amount'] as num) > 0);
    expect(credit['amount'], 3000); // 25 × 120
    expect(credit['note'], contains('Nifty Units'));
  });

  testWidgets('a SIP: pick a fund, backfill, value, and open its ledger',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeNavApi();
    await E2E.launch(tester, overrides: _offline(api));
    await E2E.openDrawerItem(tester, 'Investment');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await _fill(tester, 'Name', 'Tata Mid Cap SIP');
    await _chooseType(tester, 'sip');

    // The fund picker searches AMFI and lists direct plans first.
    await E2E.tapVisible(tester, find.text('Search for your fund'));
    await tester.enterText(find.byType(TextField).last, 'tata large');
    await tester.pump(const Duration(milliseconds: 400)); // debounce
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Direct Plan').first);
    await tester.pumpAndSettle();

    await _fill(tester, 'Amount per installment', '5000');
    // Debit on today's date so the schedule generates one installment
    // immediately, whatever day the suite happens to run.
    await _fill(tester, 'Debit day', '${DateTime.now().day}');

    // The picker opens on today, which is the date we want.
    await E2E.tapVisible(tester, find.text('Select date'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await E2E.tapVisible(
        tester, find.widgetWithText(FilledButton, 'Save investment'));

    // The engine backfilled a ledger and derived units from it.
    final ledger = E2E.lastStore!.read(SipFields.table);
    expect(ledger, isNotEmpty, reason: 'installments are generated on save');
    expect(ledger.every((e) => e['nav'] == 100), isTrue);

    final row = E2E.lastStore!
        .read('investments')
        .firstWhere((r) => r['name'] == 'Tata Mid Cap SIP');
    final units = (row['quantity'] as num).toDouble();
    expect(units, ledger.length * 50, reason: '₹5,000 ÷ NAV 100 each');
    expect(row['current_value'], units * 100,
        reason: 'the sync prices what the engine counted');
    expect(row['symbol'], '120503', reason: 'set for us from the scheme code');

    // Tapping through opens the ledger, not the edit form.
    await tester.tap(find.text('Tata Mid Cap SIP').last);
    await tester.pumpAndSettle();
    expect(find.byType(SipScreen), findsOneWidget);
    expect(find.text('Installments'), findsOneWidget);
    expect(find.textContaining('units @'), findsWidgets);

    // NAV was downloaded once for the whole journey.
    expect(api.historyCalls, 1);
  });

  testWidgets('net worth counts a holding that was never given a value',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FakeNavApi();
    await E2E.launch(tester, overrides: _offline(api));
    await E2E.openDrawerItem(tester, 'Investment');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await _fill(tester, 'Name', 'Unvalued FD');
    await _chooseType(tester, 'fd');
    await _fill(tester, 'Invested', '2000');
    // Deliberately no current value — the field is optional.
    await E2E.tapVisible(
        tester, find.widgetWithText(FilledButton, 'Save investment'));

    final saved = E2E.lastStore!
        .read('investments')
        .firstWhere((r) => r['name'] == 'Unvalued FD');
    expect(saved['current_value'], isNull);

    // It must still be worth what it cost, on the row and in net worth.
    expect(find.text(money(2000)), findsWidgets);
  });
}
