import 'package:accounts_app/core/charts.dart';
import 'package:accounts_app/features/accounts/account_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _now = DateTime(2026, 8, 2);

void main() {
  test('balance series walks opening balances forward through movements', () {
    final s = accountBalanceSeries(
      accounts: [
        {'name': 'Cash', 'opening_balance': 5000},
      ],
      income: [
        {'account': 'Cash', 'amount': 2000, 'date': '2026-02-10'},
      ],
      expenses: [
        {'account': 'Cash', 'amount': 500, 'date': '2026-03-05'},
      ],
      transfers: const [],
      cashMoves: const [],
      now: _now,
      rangeStart: DateTime(2026, 1, 1),
      rangeEnd: DateTime(2026, 12, 31),
    )!;

    expect(s.points.length, 12);
    expect(s.points[0].value, 5000); // Jan — opening only
    expect(s.points[1].value, 7000); // Feb — income lands
    expect(s.points[2].value, 6500); // Mar — expense lands
    expect(s.points[11].value, 6500);
  });

  test('transfers between own accounts net to zero overall', () {
    final s = accountBalanceSeries(
      accounts: [
        {'name': 'Cash', 'opening_balance': 1000},
        {'name': 'Bank', 'opening_balance': 1000},
      ],
      income: const [],
      expenses: const [],
      transfers: [
        {'from': 'Cash', 'to': 'Bank', 'amount': 400, 'date': '2026-02-10'},
      ],
      cashMoves: const [],
      now: _now,
      rangeStart: DateTime(2026, 1, 1),
      rangeEnd: DateTime(2026, 12, 31),
    )!;
    expect(s.points.every((p) => p.value == 2000), isTrue);
  });

  test('movements before the window are folded into its opening figure', () {
    final s = accountBalanceSeries(
      accounts: [
        {'name': 'Cash', 'opening_balance': 1000},
      ],
      income: [
        {'account': 'Cash', 'amount': 9000, 'date': '2025-06-01'},
      ],
      expenses: const [],
      transfers: const [],
      cashMoves: const [],
      now: _now,
      rangeStart: DateTime(2026, 1, 1),
      rangeEnd: DateTime(2026, 12, 31),
    )!;
    // The first bucket shows the balance as it stood, not as it started.
    expect(s.points.first.value, 10000);
  });

  test('movements against an unknown account are ignored', () {
    final s = accountBalanceSeries(
      accounts: [
        {'name': 'Cash', 'opening_balance': 1000},
      ],
      income: [
        {'account': 'Deleted account', 'amount': 5000, 'date': '2026-02-01'},
      ],
      expenses: const [],
      transfers: const [],
      cashMoves: const [],
      now: _now,
      rangeStart: DateTime(2026, 1, 1),
      rangeEnd: DateTime(2026, 12, 31),
    )!;
    expect(s.points.every((p) => p.value == 1000), isTrue);
  });

  test('cash_moves rows are already signed and applied as-is', () {
    final s = accountBalanceSeries(
      accounts: [
        {'name': 'Cash', 'opening_balance': 1000},
      ],
      income: const [],
      expenses: const [],
      transfers: const [],
      cashMoves: [
        {'account': 'Cash', 'amount': -300, 'date': '2026-02-01'},
      ],
      now: _now,
      rangeStart: DateTime(2026, 1, 1),
      rangeEnd: DateTime(2026, 12, 31),
    )!;
    expect(s.points[0].value, 1000);
    expect(s.points[1].value, 700);
  });

  test('no accounts means no series', () {
    expect(
      accountBalanceSeries(
        accounts: const [],
        income: const [],
        expenses: const [],
        transfers: const [],
        cashMoves: const [],
        now: _now,
      ),
      isNull,
    );
  });

  group('accounts screen', () {
    setUp(E2E.installSecureStorageMock);

    testWidgets('renders the balance curve above the account list', (t) async {
      await E2E.launch(t);
      await E2E.openDrawerItem(t, 'Accounts');

      // SectionLabel renders its text uppercased.
      expect(find.text('BALANCE OVER TIME'), findsOneWidget);
      expect(find.byType(SeriesChart), findsOneWidget);
      // The list itself is untouched.
      expect(find.text('HDFC Bank'), findsWidgets);
    });
  });
}
