import 'package:accounts_app/core/theme.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/data/module_event.dart';
import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/features/common/entity_screen.dart';
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

class _Repo implements FinanceRepository {
  _Repo(this.tables);
  final Map<String, List<Json>> tables;

  @override
  Future<List<Json>> list(String t,
          {String orderBy = 'created_at', bool ascending = false}) async =>
      [...(tables[t] ?? const [])];

  @override
  Future<void> insert(String t, Json v) async =>
      tables.putIfAbsent(t, () => []).add({'id': 'x', ...v});

  @override
  Future<void> update(String t, String id, Json v) async {
    final rows = tables[t] ?? [];
    final i = rows.indexWhere((r) => r['id'].toString() == id);
    if (i >= 0) rows[i] = {...rows[i], ...v};
  }

  @override
  Future<void> delete(String t, String id) async =>
      tables[t]?.removeWhere((r) => r['id'].toString() == id);

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deleting an investment takes its ledger and events with it',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tables = <String, List<Json>>{
      'investments': [
        {'id': '1', 'name': 'Mid Cap SIP', 'type': 'sip', 'scheme_code': 1},
        {'id': '2', 'name': 'Keep me', 'type': 'fund', 'invested_amount': 100},
      ],
      SipFields.table: [
        {'id': 'i1', 'parent_id': '1', 'date': '2026-01-05', 'amount': 500},
        {'id': 'i2', 'parent_id': '2', 'date': '2026-01-05', 'amount': 900},
      ],
      moduleEventsTable: [
        {'id': 'e1', 'parent_id': '1', 'parent_type': 'investments'},
        {'id': 'e2', 'parent_id': '2', 'parent_type': 'investments'},
      ],
    };

    await tester.pumpWidget(ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(_Repo(tables)),
        localStoreProvider.overrideWithValue(LocalStore(prefs)),
        navApiProvider.overrideWithValue(_NoNav()),
        quoteServiceProvider.overrideWithValue(QuoteService(
            client: MockClient((_) async => http.Response('{}', 500)))),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: EntityScreen(config: Modules.investment),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    // Confirm the destructive action.
    expect(find.text('Delete entry?'), findsOneWidget);
    expect(find.textContaining('Mid Cap SIP'), findsWidgets,
        reason: 'the row targeted must be the SIP, not its neighbour');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(tables['investments']!.map((r) => r['id']), ['2']);

    // The other row and its children are untouched.
    expect(tables[SipFields.table]!.map((e) => e['parent_id']), ['2']);
    expect(tables[moduleEventsTable]!.map((e) => e['parent_id']), ['2']);
  });
}
