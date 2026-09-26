import 'package:accounts_app/services/ask/ask_service.dart';
import 'package:accounts_app/services/ask/ask_tools.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_corpus.dart';

/// Measures the keyword router across the whole generated corpus, and prints a
/// report. Deterministic and fast — it never touches a model.
void main() {
  final corpus = buildCorpus();
  final now = DateTime(2026, 8, 15);

  test('the corpus is large and covers every tool', () {
    expect(corpus.length, greaterThanOrEqualTo(1000),
        reason: 'a spot check is not a measurement');
    final tools = corpus.map((c) => c.tool).toSet();
    expect(tools, containsAll(AskTools.all.map((t) => t.name)));
  });

  test('routing accuracy across the corpus', () {
    final byTool = <String, ({int total, int right})>{};
    final failures = <String>[];

    for (final c in corpus) {
      final choice = AskService.route(c.question, now: now);
      final ok = choice.tool == c.tool;
      final prev = byTool[c.tool] ?? (total: 0, right: 0);
      byTool[c.tool] = (total: prev.total + 1, right: prev.right + (ok ? 1 : 0));
      if (!ok && failures.length < 15) {
        failures.add('  "${c.question.trim()}" → ${choice.tool} '
            '(expected ${c.tool})');
      }
    }

    final total = corpus.length;
    final right = byTool.values.fold(0, (a, b) => a + b.right);
    final pct = right / total * 100;

    // ignore: avoid_print
    print('\n=== ROUTING ACCURACY (keyword router, $total questions) ===');
    final names = byTool.keys.toList()..sort();
    for (final tool in names) {
      final s = byTool[tool]!;
      // ignore: avoid_print
      print('  ${tool.padRight(20)} ${s.right}/${s.total}  '
          '${(s.right / s.total * 100).toStringAsFixed(1)}%');
    }
    // ignore: avoid_print
    print('  ${'OVERALL'.padRight(20)} $right/$total  '
        '${pct.toStringAsFixed(1)}%');
    if (failures.isNotEmpty) {
      // ignore: avoid_print
      print('\n  misroutes (first ${failures.length}):');
      // ignore: avoid_print
      print(failures.join('\n'));
    }

    expect(pct, greaterThanOrEqualTo(90),
        reason: 'the offline fallback must be dependable');
  });

  test('period resolution across the corpus', () {
    var checked = 0;
    var right = 0;
    final wrong = <String>[];

    for (final c in corpus) {
      if (c.period == null) continue;
      checked++;
      final resolved = AskService.route(c.question, now: now).args['period'];
      if (resolved == c.period) {
        right++;
      } else if (wrong.length < 10) {
        wrong.add('  "${c.question.trim()}" → $resolved (expected ${c.period})');
      }
    }

    // ignore: avoid_print
    print('\n=== PERIOD RESOLUTION ===');
    // ignore: avoid_print
    print('  $right/$checked  ${(right / checked * 100).toStringAsFixed(1)}%');
    if (wrong.isNotEmpty) {
      // ignore: avoid_print
      print(wrong.join('\n'));
    }

    expect(right / checked, greaterThanOrEqualTo(0.95));
  });

  group('the periods themselves resolve to the right dates', () {
    ({DateTime? from, DateTime? to}) r(String period) =>
        resolveRange({'period': period}, now);

    test('this month runs from the 1st to today', () {
      expect(r('this_month').from, DateTime(2026, 8, 1));
      expect(r('this_month').to, now);
    });

    test('last month is the whole of the previous month', () {
      expect(r('last_month').from, DateTime(2026, 7, 1));
      expect(r('last_month').to, DateTime(2026, 7, 31));
    });

    test('a named month covers that whole month', () {
      expect(r('august').from, DateTime(2026, 8, 1));
      expect(r('august').to, DateTime(2026, 8, 31));
      expect(r('feb').from, DateTime(2026, 2, 1));
      expect(r('feb').to, DateTime(2026, 2, 28));
    });

    test('a month still ahead of us means last year', () {
      // Asked in August, "December" means the December that has happened.
      expect(r('december').from, DateTime(2025, 12, 1));
      expect(r('december').to, DateTime(2025, 12, 31));
    });

    test('an explicit year is honoured', () {
      expect(r('august 2024').from, DateTime(2024, 8, 1));
      expect(r('2024-03').from, DateTime(2024, 3, 1));
      expect(r('2024-03').to, DateTime(2024, 3, 31));
    });

    test('january rolls the year boundary correctly', () {
      final jan = resolveRange({'period': 'last_month'}, DateTime(2026, 1, 10));
      expect(jan.from, DateTime(2025, 12, 1));
      expect(jan.to, DateTime(2025, 12, 31));
    });

    test('explicit dates beat any period', () {
      final range = resolveRange(
          {'period': 'this_month', 'from': '2020-01-01', 'to': '2020-01-31'},
          now);
      expect(range.from, DateTime(2020, 1, 1));
      expect(range.to, DateTime(2020, 1, 31));
    });

    test('all time is unbounded', () {
      expect(r('all').from, isNull);
      expect(r('all').to, isNull);
    });

    test('nonsense resolves to unbounded rather than throwing', () {
      expect(r('sometime last decade').from, isNull);
    });
  });
}
