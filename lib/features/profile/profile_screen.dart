import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config.dart';
import '../../core/supabase_config.dart';
import '../../core/components.dart';
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
              style: FilledButton.styleFrom(
                backgroundColor: ctx.colors.negative,
                foregroundColor: ctx.colors.surface,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;

  /// Up to two initials for the avatar ("Rohit Menon" -> "RM").
  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.screenPad, 12, AppTheme.screenPad, 24),
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accent.withValues(alpha: c.chipAlpha + 0.02),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  _initials(_name),
                  style: AppTheme.display(20, height: 26, color: c.accentText),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_name.isEmpty ? 'You' : _name,
                        style: context.text.headlineSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      SupabaseConfig.enabled
                          ? (Supabase.instance.client.auth.currentUser?.email ??
                              'Synced to your account')
                          : 'Stored on this device',
                      style: context.text.bodySmall
                          ?.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          const SectionLabel('Account'),
          SettingsRow(label: 'Name', value: _name, onTap: _editName),
          const SettingsRow(
            label: 'Currency',
            value: '${AppConfig.currencySymbol} INR',
            isLast: true,
          ),
          const SizedBox(height: 24),

          const SectionLabel('Preferences'),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: c.border),
                bottom: BorderSide(color: c.border),
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Theme', style: context.text.bodyLarge),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                          value: ThemeMode.light, label: Text('Light')),
                      ButtonSegment(
                          value: ThemeMode.dark, label: Text('Dark')),
                      ButtonSegment(
                          value: ThemeMode.system, label: Text('System')),
                    ],
                    selected: {ref.watch(themeModeProvider)},
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      foregroundColor: c.textSecondary,
                      selectedBackgroundColor:
                          c.accent.withValues(alpha: c.chipAlpha),
                      selectedForegroundColor: c.textPrimary,
                      side: BorderSide(color: c.border),
                      textStyle: context.text.labelMedium,
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.rChip),
                      ),
                    ),
                    onSelectionChanged: (s) =>
                        ref.read(themeModeProvider.notifier).state = s.first,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          const SectionLabel('Security'),
          SettingsRow(label: 'Lock app', onTap: _lock),
          SettingsRow(label: 'Reset PIN', onTap: _resetPin, isLast: true),
          const SizedBox(height: 24),

          if (SupabaseConfig.enabled)
            OutlinedButton(
              onPressed: _signOut,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.negative,
                side: BorderSide(color: c.negative),
              ),
              child: const Text('Sign out'),
            )
          else
            OutlinedButton(
              onPressed: _clearData,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.negative,
                side: BorderSide(color: c.negative),
              ),
              child: const Text('Clear all data'),
            ),
        ],
      ),
    );
  }
}
