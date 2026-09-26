import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/components.dart';
import '../../core/theme.dart';
import '../../data/nav_api.dart';
import '../../services/providers.dart';

/// Search AMFI's scheme list and pick one fund.
///
/// Typing is debounced because the endpoint is queried per keystroke otherwise,
/// and a search that fails returns no results rather than an error — a picker
/// that breaks mid-word is worse than one that finds nothing.
class FundPicker extends ConsumerStatefulWidget {
  const FundPicker({super.key});

  static Future<SchemeRef?> show(BuildContext context) {
    return showModalBottomSheet<SchemeRef>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const FundPicker(),
    );
  }

  @override
  ConsumerState<FundPicker> createState() => _FundPickerState();
}

class _FundPickerState extends ConsumerState<FundPicker> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<SchemeRef> _results = const [];
  bool _searching = false;

  /// Rising with each query so a slow response for an earlier word can't
  /// overwrite the results of a later one.
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(value));
  }

  Future<void> _search(String query) async {
    final generation = ++_generation;
    if (query.trim().length < 3) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final found = await ref.read(navApiProvider).search(query);
    if (!mounted || generation != _generation) return;
    setState(() {
      // Direct plans first: they are what retail apps sell, and their NAV is
      // the one a direct holding must be valued against.
      _results = [...found]..sort((a, b) {
          if (a.isDirect != b.isDirect) return a.isDirect ? -1 : 1;
          if (a.isGrowth != b.isGrowth) return a.isGrowth ? -1 : 1;
          return a.name.compareTo(b.name);
        });
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.screenPad, 12, AppTheme.screenPad, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetHandle(),
                Text('Find your fund', style: context.text.titleLarge),
                const SizedBox(height: 10),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    hintText: 'e.g. parag parikh flexi cap',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Pick the plan you actually hold — a regular plan\'s NAV is '
                  'lower than a direct plan\'s, and valuing one against the '
                  'other misstates your return.',
                  style:
                      context.text.labelSmall?.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: 10),
                Flexible(child: _body(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = context.colors;
    if (_results.isEmpty) {
      final typed = _controller.text.trim().length >= 3;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            _searching
                ? 'Searching…'
                : typed
                    ? 'No schemes matched that name'
                    : 'Type at least three letters',
            style: context.text.bodyMedium?.copyWith(color: c.textSecondary),
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final scheme = _results[i];
        return InkWell(
          onTap: () => Navigator.of(context).pop(scheme),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: i == 0
                  ? null
                  : Border(top: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(scheme.name, style: context.text.bodyLarge),
                      const SizedBox(height: 2),
                      Text(
                        'Scheme ${scheme.code}',
                        style: context.text.labelSmall
                            ?.copyWith(color: c.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (scheme.isDirect && scheme.isGrowth) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      border: Border.all(color: c.border),
                      borderRadius: BorderRadius.circular(AppTheme.rChip),
                    ),
                    child: Text('direct',
                        style: context.text.labelSmall
                            ?.copyWith(color: c.textSecondary)),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
