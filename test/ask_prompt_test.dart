import 'dart:io';

import 'package:accounts_app/services/ask/ask_service.dart';
import 'package:accounts_app/services/ask/ask_tools.dart';
import 'package:accounts_app/services/ask/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The system prompt is the whole of the app's side of the routing contract,
/// and it is assembled rather than written: the tool catalogue comes from
/// AskTools, the date from the clock. These check the assembly.
///
/// Set DUMP_TO to have the prompt written to that path — tool/check_ask_proxy.mjs
/// uses it to exercise the deployed proxy with the real thing rather than an
/// approximation, which turns out to matter: a paraphrased prompt without the
/// examples below routes visibly worse.
void main() {
  final prompt = OpenAiCompatibleClient.systemPrompt(
    DateTime(2026, 8, 16),
    AskService.catalogue(),
  );

  test('states today, without which "this month" means nothing', () {
    expect(prompt, contains('Today is 2026-08-16'));
  });

  test('lists every tool the app can actually run', () {
    for (final tool in AskTools.all) {
      expect(prompt, contains(tool.name),
          reason: '${tool.name} exists but the model is never told about it');
    }
  });

  test('shows worked examples, not just rules', () {
    // Without these a small model answers with the format line itself —
    // "tool; money_owed_to_me" — rather than a choice.
    expect(prompt, contains('Examples:'));
    expect(prompt, contains('spend_by_payee; period=last_month'));
  });

  test('forbids computing dates, which small models get wrong', () {
    expect(prompt, contains('Never compute dates yourself'));
  });

  test('dumps for tool/check_ask_proxy.mjs when asked', () {
    final to = Platform.environment['DUMP_TO'];
    if (to == null) return;
    File(to).writeAsStringSync(
      OpenAiCompatibleClient.systemPrompt(DateTime.now(), AskService.catalogue()),
    );
  });
}
