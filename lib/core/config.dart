/// App configuration. Data is stored entirely on-device (no backend).
class AppConfig {
  /// Single-currency app — symbol used across all money formatting.
  static const String currencySymbol = '₹'; // ₹ (INR)

  /// Opt in to the on-device sample data in a non-debug build:
  ///
  ///   flutter build web --release --dart-define=SEED_DEMO=true
  ///
  /// Debug builds seed automatically. This flag exists because a release build
  /// is the only way to run the app in some environments (the debug websocket
  /// service can't always start), and an empty demo is useless. It defaults to
  /// false, so shipped releases still start empty as before.
  static const bool seedDemoData = bool.fromEnvironment('SEED_DEMO');
}

/// Where the "Ask" feature finds a language model.
///
/// Defaults to Ollama on this machine, which needs no API key — the reason
/// that matters is that a Flutter web build is public: anything passed by
/// --dart-define ends up readable in main.dart.js, so a hosted provider's key
/// must never be set here.
///
/// This default is for local development only. A deployed build must pass its
/// own [baseUrl]: localhost belongs to whoever opened the site, so leaving the
/// default in place means every question makes a doomed request and then falls
/// back to keyword routing. The Netlify build passes `/api`, which its
/// redirects hand to netlify/functions/ask-llm.mjs — a proxy holding the key
/// server-side. Set it empty to switch the model off and route by keyword.
///
/// `/api` is relative, which follows deploy previews and custom domains for
/// free but only resolves in a browser. An iOS or Android build has to pass an
/// absolute URL (see IOS_BUILD.md).
class AskConfig {
  const AskConfig._();

  static const String baseUrl = String.fromEnvironment(
    'ASK_LLM_URL',
    defaultValue: 'http://localhost:11434/v1',
  );

  static const String model = String.fromEnvironment(
    'ASK_LLM_MODEL',
    defaultValue: 'qwen2.5-coder:7b',
  );

  /// Empty for Ollama. Only ever set this for a proxy you control.
  static const String apiKey = String.fromEnvironment('ASK_LLM_KEY');

  static bool get enabled => baseUrl.isNotEmpty;
}
