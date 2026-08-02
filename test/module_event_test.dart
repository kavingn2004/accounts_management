import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/data/module_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModuleEvent serialisation', () {
    test('writes the storage shape the metrics layer reads back', () {
      final e = ModuleEvent(
        parentId: 'sg-1',
        parentType: 'savings_goals',
        field: 'saved_amount',
        kind: EventKind.increment,
        amount: 5000,
        balanceAfter: 125000,
        date: DateTime(2026, 8, 2),
        account: 'HDFC Bank',
      );
      expect(e.toJson(), {
        'parent_id': 'sg-1',
        'parent_type': 'savings_goals',
        'field': 'saved_amount',
        'kind': 'increment',
        'amount': 5000.0,
        'balance_after': 125000.0,
        'date': '2026-08-02',
        'account': 'HDFC Bank',
      });
    });

    test('omits account and note when absent rather than writing nulls', () {
      final e = ModuleEvent(
        parentId: 'sg-1',
        parentType: 'savings_goals',
        field: 'saved_amount',
        kind: EventKind.open,
        amount: 120000,
        balanceAfter: 120000,
        date: DateTime(2026, 8, 2),
      );
      expect(e.toJson().containsKey('account'), isFalse);
      expect(e.toJson().containsKey('note'), isFalse);
    });
  });

  group('Events reader', () {
    Json ev(String id, String field, String date, double after) => {
          'parent_id': id,
          'parent_type': 'savings_goals',
          'field': field,
          'kind': 'increment',
          'amount': 100.0,
          'balance_after': after,
          'date': date,
        };

    test('forField filters by module and field, oldest first', () {
      final all = [
        ev('a', 'saved_amount', '2026-08-02', 300),
        ev('a', 'saved_amount', '2026-07-01', 100),
        ev('a', 'target_amount', '2026-07-15', 999),
        {
          ...ev('b', 'saved_amount', '2026-07-20', 200),
          'parent_type': 'investments',
        },
      ];
      final out = Events.forField(all, 'savings_goals', 'saved_amount');
      expect(out.length, 2);
      expect(out.map(Events.balanceAfter).toList(), [100.0, 300.0]);
    });

    test('rows with an unparseable date are dropped, not sorted arbitrarily',
        () {
      final out = Events.forField([
        ev('a', 'saved_amount', 'not-a-date', 50),
        ev('a', 'saved_amount', '2026-07-01', 100),
      ], 'savings_goals', 'saved_amount');
      expect(out.length, 1);
      expect(Events.balanceAfter(out.single), 100.0);
    });
  });
}
