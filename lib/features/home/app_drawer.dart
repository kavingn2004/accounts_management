import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../services/providers.dart';
import '../accounts/accounts_screen.dart';
import '../alerts/alert_providers.dart';
import '../alerts/alerts_screen.dart';
import '../common/entity_screen.dart';
import '../profile/profile_screen.dart';
import '../registry.dart';

/// Left sidebar navigation. Profile header + Dashboard + every module
/// (colour-coded) + a lock action.
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  void _openProfile(BuildContext context) {
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
  }

  void _lock(BuildContext context, WidgetRef ref) {
    Navigator.pop(context); // close drawer
    ref.read(unlockedProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Drawer(
      child: Column(
        children: [
          _header(context, ref),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                ListTile(
                  leading: const Icon(Icons.dashboard, color: AppTheme.primary),
                  title: const Text('Dashboard'),
                  onTap: () => Navigator.pop(context), // already home
                ),
                ListTile(
                  leading: _iconChip(Icons.account_balance_wallet,
                      AppTheme.cDebtor),
                  title: const Text('Accounts'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const AccountsScreen()));
                  },
                ),
                const Divider(height: 1),
                for (final m in Modules.all)
                  ListTile(
                    leading: _iconChip(m.icon, m.color),
                    title: Text(m.title),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => EntityScreen(config: m),
                        ),
                      );
                    },
                  ),
                Consumer(builder: (context, ref, _) {
                  final count = ref.watch(unreadAlertCountProvider);
                  return ListTile(
                    leading: _iconChip(Icons.notifications, AppTheme.cAlerts),
                    title: const Text('Alerts'),
                    trailing: count > 0
                        ? Badge(label: Text('$count'))
                        : const Icon(Icons.chevron_right, size: 18),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AlertsScreen(),
                        ),
                      );
                    },
                  );
                }),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.person_outline, color: AppTheme.primary),
            title: const Text('Profile'),
            onTap: () => _openProfile(context),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline, color: AppTheme.primary),
            title: const Text('Lock app'),
            onTap: () => _lock(context, ref),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'On-device • v0.1',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref) {
    final name = ref.watch(localStoreProvider).name;
    return InkWell(
      onTap: () => _openProfile(context),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 56, 20, 20),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppTheme.primary, AppTheme.accent],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: Colors.white,
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'On-device account',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Widget _iconChip(IconData icon, Color color) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }
}
