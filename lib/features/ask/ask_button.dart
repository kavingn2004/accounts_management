import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'ask_screen.dart';

/// Small round launcher for the chat.
///
/// Deliberately smaller and quieter than a module's add button: asking a
/// question is a secondary action next to recording one, and two same-sized
/// circles in a corner would compete rather than rank.
class AskButton extends StatelessWidget {
  const AskButton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: 'Ask about your money',
      child: Tooltip(
        message: 'Ask',
        child: Material(
          color: c.surface,
          shape: CircleBorder(side: BorderSide(color: c.border)),
          elevation: 0,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => AskScreen.open(context),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                Icons.forum_outlined,
                size: 20,
                color: ModuleTone.invest.of(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
