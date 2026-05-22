import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/local_repository.dart';
import 'data/local_store.dart';
import 'services/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Local on-device storage — no backend.
  final prefs = await SharedPreferences.getInstance();
  final store = LocalStore(prefs);

  // Sample data is for development/preview only. Release builds (the shipped
  // APK/IPA) start completely empty — the user adds their own accounts & data.
  if (kDebugMode) {
    await LocalRepository(store).seedIfNeeded();
  }

  runApp(
    ProviderScope(
      overrides: [localStoreProvider.overrideWithValue(store)],
      child: const AccountsApp(),
    ),
  );
}
