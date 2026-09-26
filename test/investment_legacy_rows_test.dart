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

/// Rows exactly as they existed before live tracking and the SIP engine:
/// a name, a type, and two figures typed in by hand. No symbol, no quantity,
/// no scheme code.
List<Json> _legacyRows() => [
      {
        'id': '1',
        'name': 'Nifty 50 Index',
        'type': 'fund',
        'invested_amount': 50000,
        'total_invested': 50000,
        'current_value': 58200,
      },
      {
        'id': '2',
        'name': 'Gold ETF',
        'type': 'gold',
        'invested_amount': 25000,
        'total_invested': 25000,
        'current_value': 27100,
      },
      {
        // The 'sip' type was selectable long before the engine existed, so
        // this row is a plausible thing to already have.
        'id': '3',
        'name': 'Old monthly fund',
        'type': 'sip',
        'invested_amount': 30000,
        'total_invested': 30000,
        'current_value': 34500,
      },
    ];

class _Repo implements FinanceRepository {
  _Repo(this.tables);
  final Map<String, List<Json>> tables;
  final List<String> writes = [];
  int _nextId = 100;

  @override
  Future<List<Json>> list(String table,
          {String orderBy = 'created_at', bool ascending = false}) async =>
      [...(tables[table] ?? const [])];

  @override
  Future<void> insert(String table, Json values) async {
    writes.add('insert:$table');
    tables.putIfAbsent(table, () => []).add({'id': '${_nextId++}', ...values});
  }

  @override
  Future<void> update(String table, String id, Json values) async {
    writes.add('update:$table:$id');
    final rows = tables[table] ?? [];
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) rows[i] = {...rows[i], ...values};
  }

  @override
  Future<void> delete(String table, String id) async {}
  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

/// Fails loudly if anything tries to fetch — legacy rows must cost no network.
class _NoNetworkApi implements NavApi {
  int calls = 0;
  @override
  Future<NavSeries> history(int code) async {
    calls++;
    throw const NavException('should not be called');
  }

  @override
  Future<List<SchemeRef>> search(String q) async => const [];
}

Future<_Repo> _pump(WidgetTester tester, List<Json> rows,
    {required int Function() quoteCalls}) async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  final repo = _Repo({'investments': rows});

  await tester.pumpWidget(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      localStoreProvider.overrideWithValue(store),
      navApiProvider.overrideWithValue(_NoNetworkApi()),
      quoteServiceProvider.overrideWithValue(QuoteService(
        client: MockClient((_) async {
          quoteCalls();
          return http.Response('{}', 500);
        }),
      )),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: EntityScreen(config: Modules.investment),
    ),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('existing rows are shown, priced by nothing, and never written',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var quoteCalls = 0;
    final rows = _legacyRows();
    final repo = await _pump(tester, rows, quoteCalls: () => ++quoteCalls);

    // Values are exactly as they were.
    expect(rows[0]['current_value'], 58200);
    expect(rows[1]['current_value'], 27100);
    expect(rows[2]['current_value'], 34500);

    // Nothing was written to any table, and no request was made: a row with no
    // symbol and no quantity is invisible to both engines.
    expect(repo.writes, isEmpty);
    expect(quoteCalls, 0);
    expect(repo.tables[SipFields.table], isNull,
        reason: 'no installment ledger is invented for a legacy row');

    // They render with the pre-live subtitle.
    expect(find.text(money(58200)), findsWidgets);
    expect(find.textContaining('total invested'), findsWidgets);
  });

  testWidgets('a legacy sip-typed row is not adopted by the engine',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var quoteCalls = 0;
    await _pump(tester, _legacyRows(), quoteCalls: () => ++quoteCalls);

    // Tapping it opens the edit sheet, not the SIP detail screen: without a
    // scheme code there is no ledger to show.
    await tester.tap(find.text('Old monthly fund').last);
    await tester.pumpAndSettle();

    expect(find.byType(SipScreen), findsNothing);
    expect(find.text('Update investment'), findsOneWidget);
  });

  testWidgets('editing a legacy sip-typed row asks it to become a real SIP',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var quoteCalls = 0;
    await _pump(tester, _legacyRows(), quoteCalls: () => ++quoteCalls);

    await tester.tap(find.text('Old monthly fund').last);
    await tester.pumpAndSettle();

    // This is the migration edge: the form follows the row's type, so a row
    // already typed 'sip' now shows the schedule fields and hides the money
    // fields it was created with.
    expect(find.text('Fund'), findsOneWidget);
    expect(find.text('Amount per installment'), findsOneWidget);
    expect(
      find.descendant(
          of: find.byType(TextFormField), matching: find.text('Invested')),
      findsNothing,
    );
  });

  testWidgets('a legacy row keeps its manual actions', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var quoteCalls = 0;
    await _pump(tester, _legacyRows(), quoteCalls: () => ++quoteCalls);

    await tester.drag(find.byType(ListView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();

    expect(find.text('Update current value'), findsOneWidget,
        reason: 'nothing else is maintaining this figure, so the user must be '
            'able to');
    expect(find.text('Add lumpsum'), findsNothing);
  });
}
