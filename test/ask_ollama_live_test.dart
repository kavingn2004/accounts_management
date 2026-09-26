@Tags(['live'])
library;

import 'package:accounts_app/data/finance_repository.dart';
import 'package:accounts_app/services/ask/ask_service.dart';
import 'package:accounts_app/services/ask/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Routing checked against a real model on this machine.
///
/// Skipped automatically when Ollama is not running, so the suite stays green
/// on a machine without it. Run explicitly with:
///   flutter test test/ask_ollama_live_test.dart
const _baseUrl = 'http://localhost:11434/v1';
const _model = 'qwen2.5-coder:7b';

class _Repo implements FinanceRepository {
  @override
  Future<List<Json>> list(String t,
      {String orderBy = 'created_at', bool ascending = false}) async {
    switch (t) {
      case 'expenses':
        return [
          {'date': '2026-07-11', 'amount': 2200, 'payee': 'Groceries'},
          {'date': '2026-07-03', 'amount': 8000, 'payee': 'Rent'},
          {'date': '2026-08-04', 'amount': 1500, 'payee': 'Bike service'},
        ];
      case 'income':
        return [
          {'date': '2026-07-05', 'amount': 40000, 'source': 'Salary'},
        ];
      case 'accounts':
        return [
          {'name': 'INDIAN BANK', 'type': 'bank', 'opening_balance': 5000},
        ];
      case 'investments':
        return [
          {'id': '1', 'name': 'Nifty 50', 'type': 'fund',
            'total_invested': 10000, 'current_value': 12000},
        ];
    }
    return const [];
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

Future<bool> _ollamaUp() async {
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
  late bool up;
  setUpAll(() async => up = await _ollamaUp());

  AskService service() => AskService(
        repo: _Repo(),
        llm: OpenAiCompatibleClient(baseUrl: _baseUrl, model: _model),
        clock: () => DateTime(2026, 8, 15),
      );

  /// Straight at the model. The service deliberately short-circuits questions
  /// the keyword router is sure about, so routing through it would measure the
  /// router rather than Qwen.
  Future<void> routes(String question, String expected) async {
    if (!up) {
      markTestSkipped('Ollama not running on $_baseUrl');
      return;
    }
    final client = OpenAiCompatibleClient(
      baseUrl: _baseUrl,
      model: _model,
      clock: () => DateTime(2026, 8, 15),
    );
    final choice = await client.chooseTool(question, AskService.catalogue());
    expect(choice.tool, expected, reason: 'asked: "$question"');
  }

  test('spending question', () => routes(
      'how much did I spend on groceries last month', 'spend_by_payee'),
      timeout: const Timeout(Duration(minutes: 2)));

  test('balance question', () => routes(
      'what is in my Indian Bank account', 'account_balances'),
      timeout: const Timeout(Duration(minutes: 2)));

  test('portfolio question', () => routes(
      'how are my investments doing', 'investment_summary'),
      timeout: const Timeout(Duration(minutes: 2)));

  test('earnings question', () => routes(
      'did I save anything in July', 'income_vs_expense'),
      timeout: const Timeout(Duration(minutes: 2)));

  test('the answer carries real figures, computed locally', () async {
    if (!up) {
      markTestSkipped('Ollama not running');
      return;
    }
    final result = await service().ask('how are my investments doing');
    // 12,000 against 10,000 — arithmetic the model never touched.
    expect(result.answer.text, contains('₹12,000'));
    expect(result.answer.text, contains('₹10,000'));
    expect(result.answer.rows, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
