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
  int _id = 90;
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

/// No NAV, ever — offline, or the service down, with nothing cached.
class _DeadApi implements NavApi {
  @override
  Future<NavSeries> history(int code) async =>
      throw const NavException('Could not reach the NAV service');
  @override
  Future<List<SchemeRef>> search(String q) async => const [];
}

/// A SIP as it exists straight after being created, before the engine has ever
/// managed to run: a schedule, but no ledger and no money figures.
Json _freshSip() => {
      'id': '1',
      'name': 'mid cap',
      'type': 'sip',
      'scheme_code': 122639,
      'sip_amount': 500,
      'sip_frequency': 'monthly',
      'sip_day': 5,
      'sip_start_date': '2026-01-05',
      'sip_active': true,
      'cash_from': '2026-08-02',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a SIP that cannot reach NAV says so instead of reading zero',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final tables = <String, List<Json>>{
      'investments': [_freshSip()],
    };

    await tester.pumpWidget(ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(_Repo(tables)),
        localStoreProvider.overrideWithValue(store),
        navApiProvider.overrideWithValue(_DeadApi()),
        quoteServiceProvider.overrideWithValue(QuoteService(
            client: MockClient((_) async => http.Response('{}', 500)))),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: EntityScreen(config: Modules.investment),
      ),
    ));
    await tester.pumpAndSettle();

    // Nothing could be computed — that much is honest.
    expect(tables['investments']!.single.containsKey('total_invested'), isFalse);

    // But the screen must say why, rather than presenting ₹0 as a measurement.
    expect(find.textContaining('mid cap'), findsWidgets);
    expect(find.textContaining('NAV'), findsWidgets,
        reason: 'the failure names what could not be fetched');
    expect(find.textContaining('could not be valued'), findsOneWidget);
  });
}
