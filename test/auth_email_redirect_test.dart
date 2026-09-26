import 'package:accounts_app/core/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where a confirmation email sends someone back to.
///
/// Supabase falls back to the project's Site URL when a sign-up does not say,
/// and that defaults to http://localhost:3000 — so every account created on
/// the deployed site got a confirmation link pointing at the new user's own
/// machine, where nothing is running.
void main() {
  String? redirect({
    required bool isWeb,
    String origin = 'https://kavin-accounflow.netlify.app',
    String configured = '',
  }) =>
      SupabaseConfig.resolveEmailRedirect(
        isWeb: isWeb,
        origin: () => origin,
        configured: configured,
      );

  test('on the web it returns to wherever the app is served from', () {
    expect(redirect(isWeb: true), 'https://kavin-accounflow.netlify.app');
  });

  test('which follows a deploy preview with no configuration', () {
    expect(
      redirect(isWeb: true, origin: 'https://deploy-preview-3--acc.netlify.app'),
      'https://deploy-preview-3--acc.netlify.app',
    );
  });

  test('and local development keeps working', () {
    expect(redirect(isWeb: true, origin: 'http://localhost:8080'),
        'http://localhost:8080');
  });

  test('a phone build uses the site URL it was given', () {
    expect(redirect(isWeb: false, configured: 'https://acc.example'),
        'https://acc.example');
  });

  test('a phone build with none configured defers to the dashboard', () {
    // null means "say nothing", which leaves Supabase to use its Site URL —
    // the right fallback, since a phone has no origin of its own to offer.
    expect(redirect(isWeb: false), isNull);
  });

  test('the origin is never asked for off the web', () {
    // Uri.base off the web is a file: URI, and .origin throws on one. Reading
    // it eagerly would crash sign-up on iOS and Android.
    expect(
      () => SupabaseConfig.resolveEmailRedirect(
        isWeb: false,
        origin: () => throw StateError('origin must not be read here'),
        configured: 'https://acc.example',
      ),
      returnsNormally,
    );
  });
}
