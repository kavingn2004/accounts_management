import 'package:accounts_app/core/formatters.dart';
import 'package:accounts_app/core/theme.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/features/common/entity_screen.dart';
import 'package:accounts_app/features/registry.dart';
import 'package:accounts_app/services/providers.dart';
import 'package:accounts_app/services/quotes/quote_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _yahoo = '{"chart":{"result":[{"meta":{"currency":"INR",'
    '"regularMarketPrice":1432.20,"regularMarketTime":1754130600}}]}}';

/// In-memory repository over a fixed set of investment rows.
class _Repo implements FinanceRepository {
  _Repo(this.rows);
  final List<Json> rows;

  @override
  Future<List<Json>> list(String table,
      {String orderBy = 'created_at', bool ascending = false}) async {
    return table == 'investments' ? rows : [];
  }

  @override
  Future<void> update(String table, String id, Json values) async {
    final i = rows.indexWhere((r) => r['id'] == id);
    if (i >= 0) rows[i] = {...rows[i], ...values};
  }

  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
  @override
  Future<void> insert(String table, Json values) async {}
  @override
  Future<void> delete(String table, String id) async {}
}

Future<void> _pump(
  WidgetTester tester,
  List<Json> rows, {
  required http.Client client,
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(_Repo(rows)),
      quoteServiceProvider
          .overrideWithValue(QuoteService(client: client)),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: EntityScreen(config: Modules.investment),
    ),
  ));
  await tester.pumpAndSettle();
}

Json _holding({
  String? symbol,
  num? quantity,
  num currentValue = 1000,
  String name = 'Reliance',
  String type = 'stock',
}) =>
    {
      'id': '1',
      'name': name,
      'type': type,
      'invested_amount': 10000,
      'total_invested': 10000,
      'current_value': currentValue,
      if (symbol != null) 'symbol': symbol,
      if (quantity != null) 'quantity': quantity,
    };

void main() {
  testWidgets('a live row shows the fetched value, its unit price and its age',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rows = [_holding(symbol: 'RELIANCE', quantity: 12)];
    await _pump(tester, rows,
        client: MockClient((_) async => http.Response(_yahoo, 200)));

    // 1432.20 × 12 = 17,186.40, stored and shown.
    expect(rows.single['current_value'], closeTo(17186.40, 0.01));
    expect(find.text(money(17186.40)), findsWidgets);

    // The subtitle carries the price it was valued at, so the figure above
    // is never an anonymous number.
    expect(
      find.textContaining('${money(1432.20)} × 12'),
      findsOneWidget,
    );
  });

  testWidgets('a row without a quantity keeps its manual value untouched',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rows = [_holding(symbol: 'RELIANCE', currentValue: 44000)];
    await _pump(tester, rows,
        client: MockClient((_) async => http.Response(_yahoo, 200)));

    expect(rows.single['current_value'], 44000);
    expect(find.text(money(44000)), findsWidgets);
    // Falls back to the pre-live subtitle.
    expect(find.textContaining('total invested'), findsOneWidget);
  });

  testWidgets('a failed price explains itself and keeps the last value',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final rows = [
      _holding(symbol: 'NOSUCH', quantity: 12, currentValue: 5000),
    ];
    await _pump(tester, rows,
        client: MockClient((_) async => http.Response('{}', 404)));

    expect(rows.single['current_value'], 5000,
        reason: 'a bad symbol must not blank the row');
    expect(find.textContaining('check the symbol'), findsOneWidget);
    expect(find.textContaining('last known value'), findsOneWidget);
  });

  testWidgets('the add form asks for a symbol only for priceable types',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, [],
        client: MockClient((_) async => http.Response(_yahoo, 200)));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Type defaults to 'stock', which has a price source.
    expect(find.text('Symbol (for live prices)'), findsOneWidget);
    expect(find.text('Quantity held'), findsOneWidget);
    expect(find.textContaining('NSE ticker'), findsOneWidget);
    expect(find.text('Current market price'), findsOneWidget);

    // Switching to a fixed deposit drops the fields entirely — there is
    // nothing to look up for one.
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('fd').last);
    await tester.pumpAndSettle();

    expect(find.text('Symbol (for live prices)'), findsNothing);
    expect(find.text('Quantity held'), findsNothing);
  });

  testWidgets('gold labels the market price as a per-gram rate',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester, [],
        client: MockClient((_) async => http.Response(_yahoo, 200)));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('gold').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('rate per gram'), findsOneWidget);
    expect(find.textContaining('Grams held'), findsOneWidget);
  });
}
