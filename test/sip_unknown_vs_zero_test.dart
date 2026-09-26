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

/// The ledger table does not exist — exactly the live situation.
class _NoLedgerRepo implements FinanceRepository {
  _NoLedgerRepo(this.rows);
  final List<Json> rows;

  @override
  Future<List<Json>> list(String t,
      {String orderBy = 'created_at', bool ascending = false}) async {
    if (t == SipFields.table) {
      throw Exception("Could not find the table 'public.sip_installments'");
    }
    return t == SipService.investmentsTable ? rows : [];
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

/// NAV is available — the fund is real and priced; only the ledger is missing.
class _Api implements NavApi {
  @override
  Future<NavSeries> history(int code) async {
    // A real fund publishes every business day; the schedule can only derive
    // installments for dates the fund actually existed.
    final navs = <DateTime, double>{};
    var cursor = DateTime(2026, 1, 1);
    final end = DateTime.now().add(const Duration(days: 1));
    while (cursor.isBefore(end)) {
      navs[cursor] = 580.85;
      cursor = cursor.add(const Duration(days: 1));
    }
    return NavSeries(
      code: code,
      schemeName: 'Tata Large & Mid Cap Fund Direct Plan Growth',
      fundHouse: 'Tata',
      navs: navs,
    );
  }
  @override
  Future<List<SchemeRef>> search(String q) async => const [];
}

Json _sip() => {
      'id': '1',
      'name': 'Tata Large & Mid Cap Fund Direct Plan Growth',
      'type': 'sip',
      'scheme_code': 120503,
      'sip_amount': 5000,
      'sip_frequency': 'monthly',
      'sip_day': 5,
      'sip_start_date': '2026-01-05',
    };

Future<void> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(_NoLedgerRepo([_sip()])),
      localStoreProvider.overrideWithValue(LocalStore(prefs)),
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

  testWidgets('with no ledger table, the schedule still values the holding',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _open(tester);

    // The table persists installments; it does not invent them. The schedule
    // says ₹5,000 a month since January, and the NAV says what each bought —
    // so the holding has a real value even with nowhere to store the history.
    expect(find.text('₹0'), findsNothing);
    expect(find.textContaining('580.85'), findsWidgets);
    expect(find.text('Units'), findsOneWidget);
    expect(find.text('—'), findsNothing,
        reason: 'nothing here is unknown any more');

    // And it is honest about what is missing: editing, not valuing.
    expect(find.textContaining('cannot be saved'), findsOneWidget);
    // A derived row cannot be edited, so no per-row menus are offered.
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });
}
