import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/providers.dart';
import '../home/home_shell.dart';
import 'pin_lock_screen.dart';
import 'pin_setup_screen.dart';

/// Decides which screen to show based on the on-device PIN state:
///   no PIN set -> PinSetupScreen
///   locked     -> PinLockScreen
///   unlocked   -> HomeShell
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasPin = ref.watch(hasPinProvider);
    final unlocked = ref.watch(unlockedProvider);

    return hasPin.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(body: Center(child: Text('Error: $e'))),
      data: (has) {
        if (!has) return const PinSetupScreen();
        if (!unlocked) return const PinLockScreen();
        return const HomeShell();
      },
    );
  }
}
