import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config.dart';
import 'core/supabase_config.dart';
import 'data/local_repository.dart';
import 'data/local_store.dart';
import 'services/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Cloud backend (Supabase) when configured via --dart-define; otherwise the
  // app falls back to on-device storage with no login.
  if (SupabaseConfig.enabled) {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      // Works with both legacy anon keys and new publishable keys.
      // ignore: deprecated_member_use
      anonKey: SupabaseConfig.anonKey,
    );
  }

  // Local store still holds device-level preferences (name, theme) and is the
  // data store in on-device mode.
  final prefs = await SharedPreferences.getInstance();
  final store = LocalStore(prefs);

  // Sample data is for development/preview only, and only in on-device mode.
  // Cloud mode and plain release builds start empty — the user adds their own
  // data. Pass --dart-define=SEED_DEMO=true to seed a release build too, which
  // is how the app is previewed where debug mode can't run.
  if ((kDebugMode || AppConfig.seedDemoData) && !SupabaseConfig.enabled) {
    await LocalRepository(store).seedIfNeeded();
  }

  runApp(
    ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      child: const AccountsApp(),
    ),
  );
}
