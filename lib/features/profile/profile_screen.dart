import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
import '../../core/supabase_config.dart';
import '../../core/theme.dart';
import '../../services/providers.dart';

/// User profile: local identity, currency, appearance, and device actions.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late String _name = ref.read(localStoreProvider).name;

  Future<void> _editName() async {
    final controller = TextEditingController(text: _name);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == null || saved.isEmpty) return;
    await ref.read(localStoreProvider).setName(saved);
    setState(() => _name = saved);
  }

  void _lock() {
    ref.read(unlockedProvider.notifier).state = false;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _resetPin() async {
    final ok = await _confirm('Reset PIN?',
        'You will set a new PIN next. Your data stays on the device.');
    if (!ok) return;
    await ref.read(pinServiceProvider).clearPin();
    ref.invalidate(hasPinProvider);
    if (mounted) {
      ref.read(unlockedProvider.notifier).state = false;
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _signOut() async {
    final ok = await _confirm('Sign out?',
        'You will need to sign in again to access your data.');
    if (!ok) return;
    await Supabase.instance.client.auth.signOut();
    if (mounted) {
      ref.read(unlockedProvider.notifier).state = false;
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  Future<void> _clearData() async {
    final ok = await _confirm('Clear all data?',
        'This permanently deletes everything stored on this device.');
    if (!ok) return;
    await ref.read(localStoreProvider).clearAll();
    if (mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All data cleared. Restart the app.')),
      );
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.cExpense),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                  child: Text(
                    _name.isNotEmpty ? _name[0].toUpperCase() : '?',
                    style: const TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primary),
                  ),
                ),
                const SizedBox(height: 12),
                Text(_name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                Text(
                  SupabaseConfig.enabled
                      ? (Supabase.instance.client.auth.currentUser?.email ??
                          'Synced to your account')
                      : 'Stored on this device',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person_outline,
                      color: AppTheme.primary),
                  title: const Text('Name', style: TextStyle(fontSize: 13)),
                  subtitle: Text(_name,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500)),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _editName,
                  ),
                ),
                const Divider(height: 1),
                const ListTile(
                  leading: Icon(Icons.payments_outlined,
                      color: AppTheme.primary),
                  title: Text('Currency', style: TextStyle(fontSize: 13)),
                  subtitle: Text('${AppConfig.currencySymbol}  (INR)',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Appearance — light / dark / system
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.brightness_6_outlined,
                          color: AppTheme.primary, size: 20),
                      SizedBox(width: 8),
                      Text('Appearance',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode),
                            label: Text('Light')),
                        ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode),
                            label: Text('Dark')),
                        ButtonSegment(
                            value: ThemeMode.system,
                            icon: Icon(Icons.settings_suggest),
                            label: Text('System')),
                      ],
                      selected: {ref.watch(themeModeProvider)},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => ref
                          .read(themeModeProvider.notifier)
                          .state = s.first,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          OutlinedButton.icon(
            onPressed: _lock,
            icon: const Icon(Icons.lock_outline),
            label: const Text('Lock app'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _resetPin,
            icon: const Icon(Icons.pin_outlined),
            label: const Text('Reset PIN'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: AppTheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          if (SupabaseConfig.enabled)
            OutlinedButton.icon(
              onPressed: _signOut,
              icon: const Icon(Icons.logout, color: AppTheme.cExpense),
              label: const Text('Sign out',
                  style: TextStyle(color: AppTheme.cExpense)),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                foregroundColor: AppTheme.cExpense,
              ),
            )
          else
            TextButton.icon(
              onPressed: _clearData,
              icon: const Icon(Icons.delete_forever, color: AppTheme.cExpense),
              label: const Text('Clear all data',
                  style: TextStyle(color: AppTheme.cExpense)),
            ),
        ],
      ),
    );
  }
}
