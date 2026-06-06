/// Supabase connection settings, supplied at build/run time via --dart-define
/// so the keys are never hard-coded in source. Example:
///
///   flutter run -d chrome \
///     --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=eyJhbGc...
///
/// When both values are present the app uses Supabase (cloud sync + login).
/// When they are absent it falls back to on-device storage with no login,
/// which keeps `flutter run` working for local development.
class SupabaseConfig {
  const SupabaseConfig._();

  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static bool get enabled => url.isNotEmpty && anonKey.isNotEmpty;
}
