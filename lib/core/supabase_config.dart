import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

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

  /// Where the confirmation email should send someone back to.
  ///
  /// Supabase falls back to the project's Site URL when a sign-up does not say
  /// where to return, and that setting defaults to `http://localhost:3000` —
  /// so a stranger who signs up on the deployed site gets a confirmation link
  /// pointing at their own machine, where nothing is listening.
  ///
  /// On the web the answer is simply wherever the app is being served from,
  /// which follows the custom domain, deploy previews and local development
  /// with no configuration. Elsewhere there is no such thing as "the current
  /// origin", so a build for a phone has to be told: pass
  /// `--dart-define=SITE_URL=https://your-site` or the email falls back to the
  /// Site URL in the dashboard.
  ///
  /// Whatever is returned must also be listed under Authentication → URL
  /// Configuration → Redirect URLs in the Supabase dashboard. Supabase ignores
  /// a redirect it has not been told to trust — silently, back to the Site URL.
  static String? get emailRedirectTo => resolveEmailRedirect(
        isWeb: kIsWeb,
        // Passed as a callback, not a value: off the web Uri.base is a file:
        // URI and asking it for an origin throws.
        origin: () => Uri.base.origin,
        configured: const String.fromEnvironment('SITE_URL'),
      );

  @visibleForTesting
  static String? resolveEmailRedirect({
    required bool isWeb,
    required String Function() origin,
    required String configured,
  }) =>
      isWeb ? origin() : (configured.isEmpty ? null : configured);
}
