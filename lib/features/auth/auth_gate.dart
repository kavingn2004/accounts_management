import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_config.dart';
import '../../services/providers.dart';
import '../home/home_shell.dart';
import 'login_screen.dart';
import 'pin_lock_screen.dart';
import 'pin_setup_screen.dart';

/// Decides which screen to show:
///   (cloud) not signed in -> LoginScreen
///   no PIN set            -> PinSetupScreen
///   locked                -> PinLockScreen
///   unlocked              -> HomeShell
///
/// When Supabase isn't configured the app runs in on-device mode and the login
/// step is skipped entirely (PIN-only, as before).
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (SupabaseConfig.enabled) {
      final session = ref.watch(sessionProvider);
      return session.when(
        loading: () => const _Loading(),
        error: (e, _) => _ErrorScaffold(message: '$e'),
        data: (s) => s == null ? const LoginScreen() : const _PinGate(),
      );
    }
    return const _PinGate();
  }
}

/// The on-device PIN portion of the gate (runs after sign-in, or standalone in
/// on-device mode).
class _PinGate extends ConsumerWidget {
  const _PinGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPin = ref.watch(hasPinProvider);
    final unlocked = ref.watch(unlockedProvider);

    return hasPin.when(
      loading: () => const _Loading(),
      error: (e, _) => _ErrorScaffold(message: '$e'),
      data: (has) {
        if (!has) return const PinSetupScreen();
        if (!unlocked) return const PinLockScreen();
        return const HomeShell();
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _ErrorScaffold extends StatelessWidget {
  const _ErrorScaffold({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('Error: $message')));
}
