@Tags(['live'])
library;

import 'dart:math';

import 'package:accounts_app/services/ask/ask_service.dart';
import 'package:accounts_app/services/ask/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'ask_corpus.dart';

/// Measures the real model over a stratified sample of the corpus.
///
/// The keyword router is measured over all 3,000+ questions because it is
/// instant; the model takes seconds each, so a sample is what is affordable.
/// Skips itself when Ollama is not running.
const _baseUrl = 'http://localhost:11434/v1';
const _model = 'qwen2.5-coder:7b';
const _perTool = 8;

Future<bool> _up() async {
  try {
    final res = await http
        .get(Uri.parse('http://localhost:11434/api/tags'))
        .timeout(const Duration(seconds: 3));
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('model routing accuracy over a stratified sample', () async {
    if (!await _up()) {
      markTestSkipped('Ollama not running on $_baseUrl');
      return;
    }

    // Same seed every run, so a regression is a regression and not luck.
    final rng = Random(20260815);
    final byTool = <String, List<AskCase>>{};
    for (final c in buildCorpus()) {
      // Skip the shouty and padded variants; they test the router, not routing.
      if (c.question != c.question.trim().toLowerCase()) continue;
      byTool.putIfAbsent(c.tool, () => []).add(c);
    }

    final sample = <AskCase>[];
    for (final entry in byTool.entries) {
      final pool = [...entry.value]..shuffle(rng);
      sample.addAll(pool.take(_perTool));
    }

    final client = OpenAiCompatibleClient(
      baseUrl: _baseUrl,
      model: _model,
      clock: () => DateTime(2026, 8, 15),
    );
    final catalogue = AskService.catalogue();

    final scores = <String, ({int total, int right})>{};
    final periodScore = <String, int>{'right': 0, 'checked': 0};
    final misses = <String>[];

    for (final c in sample) {
      String got;
      String? gotPeriod;
      try {
        final choice = await client.chooseTool(c.question, catalogue);
        got = choice.tool;
        gotPeriod = choice.args['period']?.toString().toLowerCase();
      } on LlmUnavailable catch (e) {
        got = 'ERROR: $e';
      }

      final ok = got == c.tool;
      final prev = scores[c.tool] ?? (total: 0, right: 0);
      scores[c.tool] = (total: prev.total + 1, right: prev.right + (ok ? 1 : 0));
      if (!ok) misses.add('  "${c.question}" → $got (expected ${c.tool})');

      if (c.period != null) {
        periodScore['checked'] = periodScore['checked']! + 1;
        // A month name may come back as the name or as a resolved range; both
        // are acceptable because the app resolves either.
        if (gotPeriod != null &&
            (gotPeriod == c.period ||
                gotPeriod.startsWith(c.period!.split(' ').first))) {
          periodScore['right'] = periodScore['right']! + 1;
        }
      }
    }

    final total = sample.length;
    final right = scores.values.fold(0, (a, b) => a + b.right);

    // ignore: avoid_print
    print('\n=== MODEL ROUTING ($_model, $total sampled questions) ===');
    final names = scores.keys.toList()..sort();
    for (final t in names) {
      final s = scores[t]!;
      // ignore: avoid_print
      print('  ${t.padRight(20)} ${s.right}/${s.total}  '
          '${(s.right / s.total * 100).toStringAsFixed(0)}%');
    }
    // ignore: avoid_print
    print('  ${'OVERALL'.padRight(20)} $right/$total  '
        '${(right / total * 100).toStringAsFixed(1)}%');
    // ignore: avoid_print
    print('  period arg          ${periodScore['right']}/'
        '${periodScore['checked']}');
    if (misses.isNotEmpty) {
      // ignore: avoid_print
      print('\n  misroutes:\n${misses.join('\n')}');
    }

    expect(right / total, greaterThanOrEqualTo(0.75),
        reason: 'the model must beat guessing by a wide margin');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
