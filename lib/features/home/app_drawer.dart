import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/components.dart';
import '../../core/theme.dart';
import '../../services/providers.dart';
import '../accounts/accounts_screen.dart';
import '../alerts/alert_providers.dart';
import '../alerts/alerts_screen.dart';
import '../common/entity_screen.dart';
import '../profile/profile_screen.dart';
import '../registry.dart';

/// Left sidebar navigation. Flat header, one tinted chip per module, and a
/// clay tint on the active row — no gradient, no blue.
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

  void _push(BuildContext context, Widget screen) {
    Navigator.pop(context);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Drawer(
      width: 296,
      child: Column(
        children: [
          _header(context, ref),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _NavRow(
                  icon: Icons.dashboard_outlined,
                  tone: ModuleTone.alerts,
                  label: 'Dashboard',
                  selected: true,
                  onTap: () => Navigator.pop(context),
                ),
                _NavRow(
                  icon: Icons.account_balance_wallet_outlined,
                  tone: ModuleTone.debtor,
                  label: 'Accounts',
                  onTap: () => _push(context, const AccountsScreen()),
                ),
                for (final m in Modules.all)
                  _NavRow(
                    icon: m.icon,
                    tone: m.tone,
                    label: m.title,
                    onTap: () => _push(context, EntityScreen(config: m)),
                  ),
                Consumer(builder: (context, ref, _) {
                  final count = ref.watch(unreadAlertCountProvider);
                  return _NavRow(
                    icon: Icons.notifications_outlined,
                    tone: ModuleTone.alerts,
                    label: 'Alerts',
                    badge: count > 0 ? '$count' : null,
                    onTap: () => _push(context, const AlertsScreen()),
                  );
                }),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Column(
              children: [
                _PlainRow(
                  label: 'Profile',
                  icon: Icons.person_outline,
                  onTap: () => _openProfile(context),
                ),
                _PlainRow(
                  label: 'Lock app',
                  icon: Icons.lock_outline,
                  onTap: () => _lock(context, ref),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'On-device • v0.1',
                    style: context.text.labelSmall
                        ?.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final name = ref.watch(localStoreProvider).name;
    return InkWell(
      onTap: () => _openProfile(context),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 56, 20, 20),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(AppTheme.rControl),
                  ),
                  child: Icon(Icons.account_balance_wallet_outlined,
                      size: 18, color: c.accent),
                ),
                const SizedBox(width: 10),
                Text('Accounflow', style: context.text.titleLarge),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              name.isEmpty ? 'On-device account' : name,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.tone,
    required this.label,
    this.badge,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final ModuleTone tone;
  final String label;
  final String? badge;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.rControl),
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? c.accent.withValues(alpha: c.chipAlpha)
                : Colors.transparent,
            border: Border.all(
              color: selected
                  ? c.accent.withValues(alpha: 0.34)
                  : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(AppTheme.rControl),
          ),
          child: Row(
            children: [
              IconChip(icon, tone),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: context.text.bodyMedium?.copyWith(
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (badge != null)
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  height: 20,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.negative.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badge!,
                    style: context.text.labelSmall?.copyWith(
                      color: c.negative,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlainRow extends StatelessWidget {
  const _PlainRow({required this.label, required this.icon, this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.rControl),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(icon, size: 18, color: c.textSecondary),
            const SizedBox(width: 12),
            Text(
              label,
              style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
