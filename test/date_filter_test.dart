import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/features/common/entity_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// July 2026, the range the default "Month" filter would produce on 2026-07-30.
final _july = DateTimeRange(
  start: DateTime(2026, 7, 1),
  end: DateTime(2026, 7, 31),
);

Json _row(String id, {Object? date, Object? createdAt}) => {
      'id': id,
      if (date != null) 'date': date,
      if (createdAt != null) 'created_at': createdAt,
    };

List<String> _ids(List<Json> rows) =>
    rows.map((r) => r['id'].toString()).toList();

void main() {
  group('filterRowsByDate — dated rows', () {
    test('keeps rows inside the range and drops rows outside it', () {
      final rows = [
        _row('in', date: '2026-07-15'),
        _row('before', date: '2026-06-30'),
        _row('after', date: '2026-08-01'),
      ];
      expect(_ids(filterRowsByDate(rows, _july)), ['in']);
    });

    test('range boundaries are inclusive on both ends', () {
      final rows = [
        _row('first', date: '2026-07-01'),
        _row('last', date: '2026-07-31'),
      ];
      expect(_ids(filterRowsByDate(rows, _july)), ['first', 'last']);
    });

    test('a null range ("All") returns every row untouched', () {
      final rows = [
        _row('dated', date: '2020-01-01'),
        _row('undated'),
        _row('garbage', date: 'not-a-date'),
      ];
      expect(_ids(filterRowsByDate(rows, null)),
          ['dated', 'undated', 'garbage']);
    });

    test('a timestamp late on the last day still counts as in range', () {
      // No trailing Z: a local wall-clock time, which is what a date field
      // widened to a timestamp looks like. Must not be excluded by the
      // end-of-range boundary.
      final rows = [_row('late', date: '2026-07-31T23:30:00')];
      expect(_ids(filterRowsByDate(rows, _july)), ['late']);
    });

    test('a UTC created_at is compared as a local calendar day', () {
      // Postgres hands back UTC timestamps; the filter boundaries are local
      // dates. Comparing the two as raw instants would drop rows near
      // midnight depending on the machine's timezone.
      final rows = [_row('mid-month', createdAt: '2026-07-15T12:00:00Z')];
      expect(_ids(filterRowsByDate(rows, _july)), ['mid-month']);
    });
  });

  group('filterRowsByDate — rows with no usable date (the bug)', () {
    test('falls back to created_at when date is missing', () {
      final rows = [
        _row('kept', createdAt: '2026-07-10T08:00:00Z'),
        _row('dropped', createdAt: '2026-05-10T08:00:00Z'),
      ];
      expect(_ids(filterRowsByDate(rows, _july)), ['kept']);
    });

    test('falls back to created_at when date is present but unparseable', () {
      final rows = [
        _row('kept', date: '', createdAt: '2026-07-10T08:00:00Z'),
        _row('also-kept', date: '15/07/2026', createdAt: '2026-07-11T08:00:00Z'),
      ];
      expect(_ids(filterRowsByDate(rows, _july)), ['kept', 'also-kept']);
    });

    test('keeps a row when neither date nor created_at can be parsed, '
        'so a stored record is never silently hidden', () {
      final rows = [
        _row('no-dates-at-all'),
        _row('junk', date: 'xxx', createdAt: 'yyy'),
      ];
      expect(_ids(filterRowsByDate(rows, _july)), ['no-dates-at-all', 'junk']);
    });

    test('a real date always wins over created_at', () {
      // date says out of range, created_at says in range -> date decides.
      final rows = [
        _row('out', date: '2026-01-05', createdAt: '2026-07-10T08:00:00Z'),
      ];
      expect(filterRowsByDate(rows, _july), isEmpty);
    });
  });
}
