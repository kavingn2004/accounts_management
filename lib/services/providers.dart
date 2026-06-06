import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase_config.dart';
import '../data/finance_repository.dart';
import '../data/local_repository.dart';
import '../data/local_store.dart';
import '../data/supabase_repository.dart';
import 'pin_service.dart';

/// Selected app theme (light / dark / follow system). Session-scoped.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final pinServiceProvider = Provider<PinService>((ref) => PinService());

/// The on-device store. Overridden in main() with the initialized instance.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider must be overridden'),
);

final repoProvider = Provider<FinanceRepository>((ref) {
  if (SupabaseConfig.enabled) {
    return SupabaseRepository(Supabase.instance.client);
  }
  return LocalRepository(ref.watch(localStoreProvider));
});

/// Supabase auth session stream (null when signed out). Only meaningful when
/// [SupabaseConfig.enabled]; emits null immediately otherwise.
final sessionProvider = StreamProvider<Session?>((ref) {
  if (!SupabaseConfig.enabled) return Stream.value(null);
  final auth = Supabase.instance.client.auth;
  return auth.onAuthStateChange.map((e) => e.session);
});

/// Whether a PIN has been set on this device.
final hasPinProvider = FutureProvider<bool>(
  (ref) => ref.read(pinServiceProvider).hasPin(),
);

/// Whether the user has entered their PIN this session (the in-app lock).
final unlockedProvider = StateProvider<bool>((ref) => false);

/// Bumped after any data mutation so dependent screens (e.g. the dashboard)
/// reload automatically instead of showing stale data.
final dataRevisionProvider = StateProvider<int>((ref) => 0);

