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
