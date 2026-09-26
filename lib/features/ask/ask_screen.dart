import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/components.dart';
import '../../core/theme.dart';
import '../../services/ask/ask_service.dart';
import '../../services/providers.dart';

/// One turn in the conversation.
class _Turn {
  _Turn.you(this.text)
      : mine = true,
        result = null,
        error = null;
  _Turn.answer(this.result)
      : mine = false,
        text = '',
        error = null;
  _Turn.failed(this.error)
      : mine = false,
        text = '',
        result = null;

  final bool mine;
  final String text;
  final AskResult? result;
  final String? error;
}

/// Chat about your own money.
///
/// Every answer is shown with the figures behind it and the tool that produced
/// it. A language model chooses which question is being asked; it never does
/// the arithmetic, and an unverifiable number on a money screen is worse than
/// no number at all.
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});

  /// Opens the chat as a sheet from the round launcher.
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AskScreen()),
    );
  }

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <_Turn>[];
  bool _busy = false;

  static const _suggestions = [
    'Where is my money going this month?',
    'What is in my bank account?',
    'How are my investments doing?',
    'What was my biggest expense?',
  ];

  @override
  void initState() {
    super.initState();
    // Load the model while the user is still reading the suggestions, so the
    // first question doesn't wait thirty seconds for 4.7GB to page in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(askServiceProvider).prewarm();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask([String? preset]) async {
    final question = (preset ?? _controller.text).trim();
    if (question.isEmpty || _busy) return;

    setState(() {
      _turns.add(_Turn.you(question));
      _controller.clear();
      _busy = true;
    });
    _toBottom();

    try {
      final result = await ref.read(askServiceProvider).ask(question);
      if (mounted) setState(() => _turns.add(_Turn.answer(result)));
    } on AskFailure catch (e) {
      if (mounted) setState(() => _turns.add(_Turn.failed(e.message)));
    } catch (e) {
      if (mounted) {
        setState(() => _turns.add(_Turn.failed('Something went wrong: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _toBottom();
    }
  }

  /// Keep the newest turn in view. Deferred a frame so the list has been laid
  /// out with the message that was just added.
  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask'),
        actions: [
          if (_turns.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(_turns.clear),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _turns.isEmpty
                ? _Empty(onPick: _ask)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(
                        AppTheme.screenPad, 12, AppTheme.screenPad, 12),
                    itemCount: _turns.length + (_busy ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _turns.length) return const _Thinking();
                      return _Bubble(turn: _turns[i]);
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.screenPad, 8, AppTheme.screenPad, 12),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _ask(),
                      decoration: const InputDecoration(
                        hintText: 'Ask about your money…',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: _busy ? null : () => _ask(),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.screenPad, 32, AppTheme.screenPad, 12),
      children: [
        Icon(Icons.forum_outlined, size: 32, color: c.textSecondary),
        const SizedBox(height: 12),
        Text('Ask about your money',
            textAlign: TextAlign.center, style: context.text.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Answers are worked out from your own records, and always show the '
          'figures behind them.',
          textAlign: TextAlign.center,
          style: context.text.bodySmall?.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: 20),
        for (final s in _AskScreenState._suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => onPick(s),
              borderRadius: BorderRadius.circular(AppTheme.rControl),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(AppTheme.rControl),
                ),
                child: Text(s, style: context.text.bodyMedium),
              ),
            ),
          ),
      ],
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text('Working it out…',
              style: context.text.labelMedium
                  ?.copyWith(color: context.colors.textSecondary)),
        ],
      ),
    );
  }
}

/// One message. Your questions sit right and tinted; answers sit left and
/// carry their workings.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});
  final _Turn turn;

  /// How the tool was chosen, for the answer's footer.
  ///
  /// Keyword routing is now only ever a stand-in for a model that is absent or
  /// unreachable, and the footer says which. These two once shared a single
  /// string that also fired when a healthy model simply was not needed, so a
  /// working model reported itself missing on every answer.
  static String _routing(AskResult result) {
    switch (result.routedBy) {
      case 'fallback':
        return ' · model unreachable, matched by keyword';
      case 'rules':
        return ' · matched by keyword, no model';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    if (turn.mine) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: c.border),
            color: c.surface,
            borderRadius: BorderRadius.circular(AppTheme.rCard),
          ),
          child: Text(turn.text, style: context.text.bodyMedium),
        ),
      );
    }

    if (turn.error != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12, right: 40),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 16, color: c.negative),
            const SizedBox(width: 8),
            Expanded(
              child: Text(turn.error!, style: context.text.bodyMedium),
            ),
          ],
        ),
      );
    }

    final result = turn.result!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14, right: 24),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.answer.text, style: context.text.bodyLarge),
            if (result.answer.rows.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final row in result.answer.rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(row.label,
                            style: context.text.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 8),
                      MoneyText(row.value),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 10),
            Text(
              'from ${result.tool}${_routing(result)}',
              style: context.text.labelSmall?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
