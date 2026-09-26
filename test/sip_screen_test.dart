import 'package:accounts_app/core/formatters.dart';
import 'package:accounts_app/core/theme.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/features/common/entity_screen.dart';
import 'package:accounts_app/features/investments/sip_screen.dart';
import 'package:accounts_app/features/registry.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:accounts_app/services/quotes/quote_service.dart';
import 'package:accounts_app/services/sip_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mutable in-memory store, so the SIP engine's writes are visible to the UI.
class _Repo implements FinanceRepository {
  _Repo(this.tables);
  final Map<String, List<Json>> tables;
  int _nextId = 100;

  @override
  Future<List<Json>> list(String table,
          {String orderBy = 'created_at', bool ascending = false}) async =>
      [...(tables[table] ?? const [])];

  @override
  Future<void> insert(String table, Json values) async {
    tables.putIfAbsent(table, () => []).add({'id': '${_nextId++}', ...values});
  }

  @override
  Future<void> update(String table, String id, Json values) async {
    final rows = tables[table] ?? [];
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) rows[i] = {...rows[i], ...values};
  }

  @override
  Future<void> delete(String table, String id) async {
    tables[table]?.removeWhere((r) => r['id'].toString() == id);
  }

  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

/// NAV of exactly 100 on every weekday of 2026, so units are round numbers.
class _FlatApi implements NavApi {
  int calls = 0;

  @override
  Future<NavSeries> history(int code) async {
    calls++;
    final navs = <DateTime, double>{};
    var cursor = DateTime(2026, 1, 1);
    while (cursor.isBefore(DateTime(2026, 12, 31))) {
      if (cursor.weekday <= DateTime.friday) navs[cursor] = 100;
      cursor = cursor.add(const Duration(days: 1));
    }
    return NavSeries(
        code: code, schemeName: 'Flexi Cap', fundHouse: 'AMC', navs: navs);
  }

  @override
  Future<List<SchemeRef>> search(String query) async => const [];
}

Json _sip({String? cashFrom}) => {
      'id': '1',
      'name': 'Flexi Cap SIP',
      'type': 'sip',
      'scheme_code': 122639,
      'sip_start_date': '2026-01-05',
      'sip_amount': 5000,
      'sip_frequency': 'monthly',
      'sip_day': 5,
      'sip_active': true,
      if (cashFrom != null) 'cash_from': cashFrom,
    };

Future<Map<String, List<Json>>> _pumpInvestments(
  WidgetTester tester, {
  required Map<String, List<Json>> tables,
  NavApi? api,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(_Repo(tables)),
      // The NAV cache persists through this, so it must be a real store.
      localStoreProvider.overrideWithValue(store),
      navApiProvider.overrideWithValue(api ?? _FlatApi()),
      // The MF quote source and the SIP engine both read NAV; the sync's
      // fetch is stubbed with the same flat figure.
      quoteServiceProvider.overrideWithValue(QuoteService(
        client: MockClient((_) async => http.Response(
            '{"data":[{"date":"20-04-2026","nav":"100.00000"}]}', 200)),
      )),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: EntityScreen(config: Modules.investment),
    ),
  ));
  await tester.pumpAndSettle();
  return tables;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opening the Investment screen backfills a SIP and values it',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = <String, List<Json>>{
      'investments': [_sip()],
    };
    await _pumpInvestments(tester, tables: tables);

    // The ledger was generated from the schedule...
    final ledger = tables[SipFields.table]!;
    expect(ledger, isNotEmpty);
    expect(ledger.every((e) => e[InstallmentFields.nav] == 100), isTrue);

    // ...units were written to quantity by the engine...
    final row = tables['investments']!.single;
    final units = (row['quantity'] as num).toDouble();
    expect(units, ledger.length * 50); // ₹5,000 ÷ NAV 100

    // ...and the sync valued them, without the engine writing current_value.
    expect((row['current_value'] as num).toDouble(), units * 100);
    expect(row['total_invested'], ledger.length * 5000);
  });

  testWidgets('a SIP row opens its detail screen, not the edit form',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpInvestments(tester, tables: {
      'investments': [_sip()],
    });

    // The dashboard's breakdown bar carries the same label, so target the
    // list row itself — the last match down the tree.
    await tester.tap(find.text('Flexi Cap SIP').last);
    await tester.pumpAndSettle();

    expect(find.byType(SipScreen), findsOneWidget);
    expect(find.text('Current value'), findsOneWidget);
    expect(find.text('Installments'), findsOneWidget);
    expect(find.text('XIRR'), findsOneWidget);
    // Every generated installment is listed with the NAV it bought at.
    expect(find.textContaining('units @'), findsWidgets);
  });

  testWidgets('a due installment raises a banner that posts cash once',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // A boundary in the past means the recent installments are "live" ones.
    final tables = <String, List<Json>>{
      'investments': [_sip(cashFrom: '2026-01-01')],
      'accounts': [
        {'id': 'a1', 'name': 'HDFC', 'type': 'bank'}
      ],
    };
    await _pumpInvestments(tester, tables: tables);

    // The banner is up on the first load: the engine re-reads the ledger it
    // just wrote so the new installment is actionable straight away.
    expect(find.textContaining('SIP installment'), findsOneWidget);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    final moves = tables['cash_moves'] ?? const [];
    expect(moves, hasLength(1), reason: 'exactly one debit per confirmation');
    expect(moves.single['amount'], -5000);
    expect(moves.single['account'], 'HDFC');

    final posted = tables[SipFields.table]!
        .where((e) => e[InstallmentFields.cashPosted] == true);
    expect(posted, hasLength(1));
  });

  testWidgets('the add form swaps to SIP fields when the type changes',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpInvestments(tester, tables: {'investments': []});

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Default type is a stock: money fields, no schedule.
    Finder formField(String label) => find.descendant(
        of: find.byType(TextFormField), matching: find.text(label));
    expect(formField('Invested'), findsOneWidget);
    expect(find.text('Fund'), findsNothing);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('sip').last);
    await tester.pumpAndSettle();

    // A SIP is described by its schedule; its money figures are derived, so
    // they are no longer offered for typing.
    expect(find.text('Fund'), findsOneWidget);
    expect(find.text('Amount per installment'), findsOneWidget);
    expect(find.text('First installment'), findsOneWidget);
    expect(formField('Invested'), findsNothing);
    expect(formField('Current value'), findsNothing);
    expect(find.text('Symbol (for live prices)'), findsNothing);
  });

  testWidgets('a SIP row offers lumpsum and pause, not the manual actions',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpInvestments(tester, tables: {
      'investments': [_sip()],
    });

    await tester.drag(find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();

    expect(find.text('Add lumpsum'), findsOneWidget);
    expect(find.text('Pause SIP'), findsOneWidget);
    expect(find.text('Update current value'), findsNothing,
        reason: 'the engine owns this figure — a manual set would fight it');
  });

  testWidgets('NAV is downloaded once a day, not once per screen visit',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final api = _FlatApi();
    await _pumpInvestments(tester,
        tables: {
          'investments': [_sip()],
        },
        api: api);
    expect(api.calls, 1);

    // Opening the detail screen and coming back must not re-download.
    await tester.tap(find.text('Flexi Cap SIP').last);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(api.calls, 1, reason: 'NAV is published once a day');
  });

  testWidgets('formatting: the list row shows NAV, units and freshness',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = <String, List<Json>>{
      'investments': [_sip()],
    };
    await _pumpInvestments(tester, tables: tables);

    final units = (tables['investments']!.single['quantity'] as num).toDouble();
    expect(
      find.textContaining('${money(100)} × ${quantityText(units)}'),
      findsOneWidget,
    );
  });
}
