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
  Future<void> delete(String t, String id) async =>
      tables[t]?.removeWhere((r) => r['id'].toString() == id);

  @override
  Future<Json?> dashboard() async => null;
  @override
  Future<List<Json>> accountsWithBalances() async => [];
}

/// Flat NAV of 100 across 2026, so units are whole numbers.
class _FlatApi implements NavApi {
  @override
  Future<NavSeries> history(int code) async {
    final navs = <DateTime, double>{};
    var cursor = DateTime(2026, 1, 1);
    while (cursor.isBefore(DateTime(2026, 12, 31))) {
      if (cursor.weekday <= DateTime.friday) navs[cursor] = 100;
      cursor = cursor.add(const Duration(days: 1));
    }
    return NavSeries(code: code, schemeName: 'Mid', fundHouse: 'A', navs: navs);
  }

  @override
  Future<List<SchemeRef>> search(String q) async => const [];
}

Json _sipRow() => {
      'id': '1',
      'name': 'mid cap',
      'type': 'sip',
      'scheme_code': 122639,
      'sip_amount': 5000,
      'sip_frequency': 'monthly',
      'sip_day': 5,
      'sip_start_date': '2026-01-05',
      // Paused, so a refresh cannot backfill new installments mid-test and
      // muddy what the action itself did.
      'sip_active': false,
      'quantity': 100,
      'total_invested': 10000,
    };

/// Two already-allotted installments, as the engine would have written them.
List<Json> _ledger() => [
      {
        'id': 'i1',
        'parent_id': '1',
        'date': '2026-01-05',
        'amount': 5000,
        'nav': 100,
        'nav_date': '2026-01-05',
        'units': 50,
        'source': 'auto',
      },
      {
        'id': 'i2',
        'parent_id': '1',
        'date': '2026-02-05',
        'amount': 5000,
        'nav': 100,
        'nav_date': '2026-02-05',
        'units': 50,
        'source': 'auto',
      },
      {
        'id': 'i3',
        'parent_id': '1',
        'date': '2026-03-10',
        'amount': 2000,
        'nav': 100,
        'nav_date': '2026-03-10',
        'units': 20,
        'source': 'manual',
      },
    ];

Future<Map<String, List<Json>>> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  final tables = <String, List<Json>>{
    'investments': [_sipRow()],
    SipFields.table: _ledger(),
  };

  await tester.pumpWidget(ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(_Repo(tables)),
      localStoreProvider.overrideWithValue(store),
      navApiProvider.overrideWithValue(_FlatApi()),
      quoteServiceProvider.overrideWithValue(QuoteService(
        client: MockClient((_) async => http.Response(
            '{"data":[{"date":"05-03-2026","nav":"100.00000"}]}', 200)),
      )),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      home: SipScreen(row: _sipRow()),
    ),
  ));
  await tester.pumpAndSettle();
  return tables;
}

/// Rows render newest first: 0 = the March lumpsum, 1 = Feb scheduled,
/// 2 = Jan scheduled.
Future<void> _openMenu(WidgetTester tester, int row) async {
  await tester.tap(find.byIcon(Icons.more_vert).at(row));
  await tester.pumpAndSettle();
}

Future<void> _tapMenu(WidgetTester tester, int row, String label) async {
  await _openMenu(tester, row);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

const _lumpsumRow = 0;
const _scheduledRow = 1;

/// Skip a row through the reason dialog, leaving the note blank.
Future<void> _skip(WidgetTester tester, int row) async {
  await _tapMenu(tester, row, 'Skip this one');
  await tester.tap(find.widgetWithText(FilledButton, 'Skip'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('skipping an installment sticks and drops the units',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    // The ledger totals 120 units; skip the Feb scheduled one, worth 50.
    await _skip(tester, _scheduledRow);

    final ledger = tables[SipFields.table]!;
    expect(ledger.where((e) => e['skipped'] == true), hasLength(1),
        reason: 'the skip must persist');
    expect(ledger, hasLength(3), reason: 'it stays in the ledger, struck out');

    expect(tables['investments']!.single['quantity'], 70); // 120 − 50
    expect(tables['investments']!.single['total_invested'], 7000);
  });

  testWidgets('skipping records a note saying why', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _openMenu(tester, _scheduledRow);
    await tester.tap(find.text('Skip this one').last);
    await tester.pumpAndSettle();

    // A reason is asked for, and optional.
    expect(find.text('Skip this installment'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'mandate bounced');
    await tester.tap(find.widgetWithText(FilledButton, 'Skip'));
    await tester.pumpAndSettle();

    final skipped = tables[SipFields.table]!
        .firstWhere((e) => e['skipped'] == true);
    expect(skipped['note'], 'mandate bounced');

    // And it is visible on the row, not just stored.
    expect(find.textContaining('mandate bounced'), findsOneWidget);
  });

  testWidgets('cancelling the reason leaves the installment alone',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _openMenu(tester, _scheduledRow);
    await tester.tap(find.text('Skip this one').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(tables[SipFields.table]!.any((e) => e['skipped'] == true), isFalse);
    expect(tables[SipFields.table]!.any((e) => e['note'] != null), isFalse);
    // Untouched: cancelling writes nothing, so not even a recompute runs and
    // the row still holds exactly what it held before.
    expect(tables['investments']!.single['quantity'], 100);
  });

  testWidgets('un-skipping clears the note with it', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _openMenu(tester, _scheduledRow);
    await tester.tap(find.text('Skip this one').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mandate bounced');
    await tester.tap(find.widgetWithText(FilledButton, 'Skip'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Un-skip'));
    await tester.pumpAndSettle();

    final row = tables[SipFields.table]!
        .firstWhere((e) => e['date'] == '2026-02-05');
    expect(row['skipped'], isFalse);
    expect(row['note'], isNull,
        reason: 'the reason described the skip, so it goes with it');
  });

  testWidgets('a skipped row carries its own Un-skip button', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    expect(find.text('Un-skip'), findsNothing,
        reason: 'nothing is skipped yet');

    await _skip(tester, _scheduledRow);

    // The row stays listed, struck through, with a one-tap way back.
    expect(find.text('skipped'), findsOneWidget);
    expect(find.text('Un-skip'), findsOneWidget);

    await tester.tap(find.text('Un-skip'));
    await tester.pumpAndSettle();

    expect(tables['investments']!.single['quantity'], 120);
    expect(find.text('Un-skip'), findsNothing);
  });

  testWidgets('un-skipping puts the units back', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    await _skip(tester, _scheduledRow);
    expect(tables['investments']!.single['quantity'], 70);

    await tester.tap(find.text('Un-skip'));
    await tester.pumpAndSettle();
    expect(tables['investments']!.single['quantity'], 120);
  });

  testWidgets('a scheduled installment offers no Delete — it would come back',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _open(tester);
    await _openMenu(tester, _scheduledRow);

    expect(find.text('Skip this one'), findsOneWidget);
    expect(find.text('Delete'), findsNothing,
        reason: 'the schedule regenerates it, so Delete would undo itself');
  });

  testWidgets('a lumpsum can be deleted, and stays deleted', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tables = await _open(tester);
    expect(tables[SipFields.table], hasLength(3));

    await _openMenu(tester, _lumpsumRow);
    expect(find.text('Delete'), findsOneWidget,
        reason: 'nothing regenerates a manual purchase');
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(tables[SipFields.table], hasLength(2));
    expect(
      tables[SipFields.table]!.any((e) => e['source'] == 'manual'),
      isFalse,
    );
    expect(tables['investments']!.single['quantity'], 100);
  });
}
