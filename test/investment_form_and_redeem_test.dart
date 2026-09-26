import 'package:accounts_app/core/formatters.dart';
import 'package:accounts_app/core/theme.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/data/nav_api.dart';
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

class _Repo implements FinanceRepository {
  _Repo(this.tables);
  final Map<String, List<Json>> tables;
  int _id = 700;

  @override
  Future<List<Json>> list(String t,
          {String orderBy = 'created_at', bool ascending = false}) async =>
      [...(tables[t] ?? const [])];

  @override
  Future<void> insert(String t, Json v) async =>
      tables.putIfAbsent(t, () => []).add({'id': '${_id++}', ...v});

  @override
  Future<void> update(String t, String id, Json v) async {
    final rows = tables[t] ?? [];
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) rows[i] = {...rows[i], ...v};
  }

  @override
  Future<void> delete(String t, String id) async {}
  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

class _NoNav implements NavApi {
  @override
  Future<NavSeries> history(int code) async =>
      throw const NavException('offline');
  @override
  Future<List<SchemeRef>> search(String q) async => const [];
}

Future<Map<String, List<Json>>> _pump(
  WidgetTester tester, {
  List<Json>? investments,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  final tables = <String, List<Json>>{
    'investments': investments ?? [],
    'accounts': [
      {'id': 'a1', 'name': 'Indian Bank', 'type': 'bank'},
      {'id': 'a2', 'name': 'Cash', 'type': 'cash'},
    ],
  };

  await tester.pumpWidget(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(_Repo(tables)),
      localStoreProvider.overrideWithValue(store),
      navApiProvider.overrideWithValue(_NoNav()),
      quoteServiceProvider.overrideWithValue(
          QuoteService(client: MockClient((_) async => http.Response('{}', 500)))),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: EntityScreen(config: Modules.investment),
    ),
  ));
  await tester.pumpAndSettle();
  return tables;
}

Finder _field(String label) =>
    find.descendant(of: find.byType(TextFormField), matching: find.text(label));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the form', () {
    testWidgets('groups fields under headings', (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pump(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('MONEY'), findsOneWidget);
      expect(find.text('HOLDING'), findsOneWidget);
      expect(find.text('SCHEDULE'), findsNothing,
          reason: 'a stock has no schedule');
    });

    testWidgets('a quantity replaces the current-value question',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pump(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Both ways of describing worth are offered while neither is used.
      expect(_field('Current value'), findsOneWidget);
      expect(_field('Quantity held'), findsOneWidget);

      await tester.enterText(_qtyField(tester), '100');
      await tester.pumpAndSettle();

      // Now the holding is described by units, so asking for the total as
      // well would only invite the two to disagree.
      expect(_field('Current value'), findsNothing);
      expect(_field('Quantity held'), findsOneWidget);
    });

    testWidgets('a SIP swaps Money and Holding for Schedule', (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pump(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('sip').last);
      await tester.pumpAndSettle();

      expect(find.text('SCHEDULE'), findsOneWidget);
      expect(find.text('MONEY'), findsNothing,
          reason: 'every figure is derived from the ledger');
      expect(find.text('HOLDING'), findsNothing);
    });
  });

  group('redeem', () {
    Json holding() => {
          'id': '1',
          'name': 'Nifty 50 Index',
          'type': 'fund',
          'quantity': 100,
          'market_price': 120,
          'last_price': 120,
          'total_invested': 10000,
          'current_value': 12000,
        };

    testWidgets('units and amount stay in step, and the money lands',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tables = await _pump(tester, investments: [holding()]);

      await tester.drag(find.byType(ListView).last, const Offset(0, -220));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Redeem').last);
      await tester.pumpAndSettle();

      // Typing units fills the amount at the current price.
      await tester.enterText(find.byType(TextField).first, '25');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '3000.00'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Redeem'));
      await tester.pumpAndSettle();

      final row = tables['investments']!.single;
      expect(row['quantity'], 75);
      expect(row['current_value'], 9000);

      final move = tables['cash_moves']!.single;
      expect(move['amount'], 3000, reason: 'money in');
      expect(move['account'], 'Indian Bank');
    });

    testWidgets('"Redeem all" fills the whole holding', (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tables = await _pump(tester, investments: [holding()]);

      await tester.drag(find.byType(ListView).last, const Offset(0, -220));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Redeem').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Redeem all'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Redeem'));
      await tester.pumpAndSettle();

      expect(tables['investments']!.single['quantity'], 0);
      expect(tables['cash_moves']!.single['amount'], 12000);
    });

    testWidgets('the dialog states what is held and what it is worth',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _pump(tester, investments: [holding()]);
      await tester.drag(find.byType(ListView).last, const Offset(0, -220));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Redeem').last);
      await tester.pumpAndSettle();

      expect(
        find.text('Holding 100 at ${money(120)} — worth ${money(12000)}'),
        findsOneWidget,
      );
    });
  });
}

/// The quantity input, found by walking up from its label.
Finder _qtyField(WidgetTester tester) => find.ancestor(
      of: find.text('Quantity held'),
      matching: find.byType(TextFormField),
    );
