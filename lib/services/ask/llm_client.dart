import 'dart:convert';

import 'package:http/http.dart' as http;

/// The model's decision: which tool to call, and with what.
class ToolChoice {
  const ToolChoice(this.tool, this.args);
  final String tool;
  final Map<String, dynamic> args;

  @override
  String toString() => '$tool(${jsonEncode(args)})';
}

class LlmUnavailable implements Exception {
  const LlmUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Picks a tool for a question.
abstract class LlmClient {
  Future<ToolChoice> chooseTool(String question, String toolCatalogue);

  /// Load the model before it is needed, so the first real question does not
  /// pay for it. Best-effort — failure here must never surface.
  Future<void> prewarm() async {}
}

/// Any server speaking the OpenAI `/chat/completions` shape.
///
/// Ollama serves it at `http://localhost:11434/v1`, and so do Together, Groq
/// and most hosted providers — so moving from a local model to a hosted one is
/// a base URL and a key, not a rewrite.
///
/// No API key is needed for Ollama, which is the point of running it locally:
/// there is no secret to leak into a web bundle, and nothing at all leaves the
/// machine. A deployed build cannot reach anyone's Ollama, so it points
/// [baseUrl] at a proxy that holds the key instead — same shape, same client,
/// see netlify/functions/ask-llm.mjs.
class OpenAiCompatibleClient implements LlmClient {
  OpenAiCompatibleClient({
    required this.baseUrl,
    required this.model,
    this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
    DateTime Function()? clock,
  })  : _http = client ?? http.Client(),
        _now = clock ?? DateTime.now;

  final String baseUrl;
  final String model;
  final String? apiKey;
  final Duration timeout;
  final http.Client _http;
  final DateTime Function() _now;

  /// The date has to be stated. Without it "this month" and "August" are
  /// unanswerable, and a model with no clock quietly invents a year.
  /// Generation is the slow part on a CPU — about five tokens a second — so
  /// the reply format is chosen to be short. A compact line costs roughly a
  /// third of the tokens of the equivalent JSON object, which is seconds off
  /// every answer.
  static String systemPrompt(DateTime now, String toolCatalogue) => '''
You route a personal-finance question to exactly one tool.

Today is ${now.toIso8601String().split('T').first}.

Reply with ONE line and nothing else:
tool; arg=value; arg=value

Rules:
- Use only the tools listed. Never invent a tool or an argument.
- For a time span use period= with one of: today, this_week, this_month,
  last_month, this_year, last_year, all — or a month name such as august.
  Never compute dates yourself; the app resolves the period.
- Say last_month or this_month rather than naming the month. Asked about
  "last month" a small model reliably names the current one instead.
- Give each argument at most once.
- Omit arguments you have no value for. No quotes, no JSON, no explanation.

Examples:
spend_by_payee; period=last_month
account_balances
sip_detail; name=tata

Tools:
$toolCatalogue''';

  @override
  Future<ToolChoice> chooseTool(String question, String toolCatalogue) async {
    final uri = Uri.parse('$baseUrl/chat/completions');
    final http.Response res;
    try {
      res = await _http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (apiKey != null && apiKey!.isNotEmpty)
                'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              // Deterministic: the same question must route the same way twice,
              // or an answer about money stops being reproducible.
              'temperature': 0,
              // One short line is all that is wanted; without a cap a chatty
              // model can spend ten seconds explaining itself.
              'max_tokens': 40,
              'messages': [
                {
                  'role': 'system',
                  'content': systemPrompt(_now(), toolCatalogue),
                },
                {'role': 'user', 'content': question},
              ],
            }),
          )
          .timeout(timeout);
    } catch (e) {
      throw LlmUnavailable(
          'Could not reach the model at $baseUrl — is Ollama running?');
    }

    if (res.statusCode != 200) {
      throw LlmUnavailable('Model returned ${res.statusCode}');
    }

    final String content;
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      content = (body['choices'] as List).first['message']['content'] as String;
    } catch (_) {
      throw const LlmUnavailable('Unexpected response from the model');
    }

    return parseChoice(content);
  }

  /// Pull the decision out of whatever the model wrapped it in.
  ///
  /// Two shapes are accepted: the compact line that is asked for, and a JSON
  /// object, because a model told to emit one format will sometimes emit the
  /// other and rejecting a usable answer helps nobody.
  static ToolChoice parseChoice(String content) {
    final text = content.trim();
    if (!text.contains('{')) return _parseCompact(text);
    final start = content.indexOf('{');
    final end = content.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const LlmUnavailable('The model did not return a tool choice');
    }
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(content.substring(start, end + 1))
          as Map<String, dynamic>;
    } catch (_) {
      throw const LlmUnavailable('The model returned malformed JSON');
    }

    final tool = (decoded['tool'] ?? decoded['name'] ?? '').toString().trim();
    if (tool.isEmpty) {
      throw const LlmUnavailable('The model named no tool');
    }
    final rawArgs = decoded['args'] ?? decoded['arguments'] ?? const {};
    return ToolChoice(
      tool,
      rawArgs is Map
          ? rawArgs.map((k, v) => MapEntry(k.toString(), v))
          : const {},
    );
  }

  /// `tool; arg=value; arg=value` — the format the prompt asks for.
  static ToolChoice _parseCompact(String text) {
    // Take the first non-empty line: a stray sign-off cannot then corrupt it.
    final line = text
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (line.isEmpty) {
      throw const LlmUnavailable('The model did not return a tool choice');
    }

    final parts = line.split(RegExp('[;,]'));
    final tool = parts.first.trim().toLowerCase();
    // A tool name, not a sentence. Prose contains spaces and punctuation, and
    // squeezing it into something name-shaped would invent a decision the
    // model never made.
    if (!RegExp(r'^[a-z][a-z0-9_]{2,}$').hasMatch(tool)) {
      throw const LlmUnavailable('The model named no tool');
    }

    final args = <String, dynamic>{};
    for (final part in parts.skip(1)) {
      final eq = part.indexOf('=');
      if (eq < 1) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      final value = part.substring(eq + 1).trim().replaceAll('"', '');
      if (key.isNotEmpty && value.isNotEmpty) args[key] = value;
    }
    return ToolChoice(tool, args);
  }

  /// Ollama unloads an idle model after five minutes, and reloading 4.7GB
  /// costs about thirty seconds — paid by whoever asks the next question.
  /// A one-token request pins it back in memory.
  @override
  Future<void> prewarm() async {
    if (!baseUrl.contains('localhost') && !baseUrl.contains('11434')) return;
    final native = baseUrl.replaceAll('/v1', '');
    try {
      await _http
          .post(
            Uri.parse('$native/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'stream': false,
              'keep_alive': '30m',
              'options': {'num_predict': 1},
              'messages': [
                {'role': 'user', 'content': 'hi'}
              ],
            }),
          )
          .timeout(const Duration(seconds: 60));
    } catch (_) {
      // Best effort. A cold model just costs the first question its load time.
    }
  }
}
