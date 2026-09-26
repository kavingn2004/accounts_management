import 'package:accounts_app/core/theme.dart';
import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/local_store.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

/// Reads fail the way a cloud backend fails: a missing table, an expired
/// session, a dropped connection.
class _FailingRepo implements FinanceRepository {
  _FailingRepo({this.failInvestments = false, this.failLedger = false});
  final bool failInvestments;
  final bool failLedger;

  @override
  Future<List<Json>> list(String t,
      {String orderBy = 'created_at', bool ascending = false}) async {
    if (t == SipService.investmentsTable && failInvestments) {
      throw Exception('relation "public.investments" does not exist');
    }
    if (t == SipFields.table && failLedger) {
      throw Exception('relation "public.sip_installments" does not exist');
    }
    return [];
  }

  @override
  Future<void> insert(String t, Json v) async {}
  @override
  Future<void> update(String t, String id, Json v) async {}
  @override
  Future<void> delete(String t, String id) async {}
  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

/// Storage that refuses to write — a browser localStorage quota, say.
class _FullStore extends LocalStore {
  _FullStore(super.prefs);

  @override
  Future<void> writeNav(String key, String json) async =>
      throw Exception('QuotaExceededError');
}

class _Api implements NavApi {
  @override
  Future<NavSeries> history(int code) async => NavSeries(
        code: code,
        schemeName: 'Mid Cap',
        fundHouse: 'AMC',
        navs: {DateTime(2026, 8, 1): 90},
      );
  @override
  Future<List<SchemeRef>> search(String q) async => const [];
}

Json _sip() => {
      'id': '1',
      'name': 'Mid Cap SIP',
      'type': 'sip',
      'scheme_code': 122639,
      'sip_amount': 500,
      'sip_start_date': '2026-01-05',
      'sip_frequency': 'monthly',
      'sip_day': 5,
    };

Future<void> _open(
  WidgetTester tester, {
  required FinanceRepository repo,
  LocalStore? store,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      localStoreProvider.overrideWithValue(store ?? LocalStore(prefs)),
      navApiProvider.overrideWithValue(_Api()),
      quoteServiceProvider.overrideWithValue(
          QuoteService(client: MockClient((_) async => http.Response('{}', 500)))),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: SipScreen(row: _sip()),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a failed row read falls back to the row it was opened with',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _open(tester, repo: _FailingRepo(failInvestments: true));

    // The screen was handed a row; a failed re-read is no reason to show
    // nothing at all.
    expect(find.text('Could not load this SIP'), findsNothing);
    expect(find.text('Current value'), findsOneWidget);
    expect(find.textContaining('could not be re-read'), findsOneWidget);
  });

  testWidgets('a missing ledger table shows the screen and says so',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _open(tester, repo: _FailingRepo(failLedger: true));

    expect(find.text('Could not load this SIP'), findsNothing);
    expect(find.text('Installments'), findsOneWidget);
    expect(find.textContaining('sip_installments'), findsOneWidget,
        reason: 'the reason must name the missing table, not hide it');
  });

  testWidgets('storage that cannot cache NAV does not break the screen',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await _open(tester, repo: _FailingRepo(), store: _FullStore(prefs));

    expect(find.text('Could not load this SIP'), findsNothing);
    expect(find.text('Current value'), findsOneWidget);
  });
}
