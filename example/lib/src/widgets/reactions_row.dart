import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;

/// Reaction chips under a message bubble (emoji + count). Tapping one
/// toggles the current user's reaction.
class ReactionsRow extends StatelessWidget {
  const ReactionsRow({
    super.key,
    required this.message,
    required this.currentUserId,
    required this.onToggle,
    required this.alignEnd,
  });

  final core.Message message;
  final String currentUserId;
  final void Function(String emoji) onToggle;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final reactions = message.reactions;
    if (reactions == null || reactions.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Wrap(
        alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final MapEntry(key: emoji, value: users) in reactions.entries)
            Material(
              color: users.contains(currentUserId)
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              shape: StadiumBorder(
                side: BorderSide(
                  color: users.contains(currentUserId)
                      ? scheme.primary.withValues(alpha: .5)
                      : Colors.transparent,
                ),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => onToggle(emoji),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: Text(
                    users.length > 1 ? '$emoji ${users.length}' : emoji,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
