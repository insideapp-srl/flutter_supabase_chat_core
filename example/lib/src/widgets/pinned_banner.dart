import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../utils/format.dart';

/// Telegram-style pinned message bar under the app bar. With several
/// pinned messages, each tap jumps to the current one and moves on to the
/// next (older) one; a vertical indicator shows the position.
class PinnedBanner extends StatefulWidget {
  const PinnedBanner({
    super.key,
    required this.controller,
    required this.onJump,
    this.onUnpin,
  });

  final SupabaseChatController controller;
  final void Function(core.Message message) onJump;

  /// Shown as an "x" when the user may unpin (admins / direct rooms).
  final void Function(core.Message message)? onUnpin;

  @override
  State<PinnedBanner> createState() => _PinnedBannerState();
}

class _PinnedBannerState extends State<PinnedBanner> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<List<core.Message>>(
      valueListenable: widget.controller.pinnedMessages,
      builder: (context, pinned, _) {
        final show = pinned.isNotEmpty;
        final index = show ? _index % pinned.length : 0;
        final message = show ? pinned[index] : null;
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: message == null
              ? const SizedBox(width: double.infinity)
              : Material(
                  color: scheme.surface,
                  child: InkWell(
                    onTap: () {
                      widget.onJump(message);
                      setState(() => _index = index + 1);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color:
                                theme.dividerTheme.color ??
                                scheme.outlineVariant,
                            width: .5,
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                      child: Row(
                        spacing: 10,
                        children: [
                          _PositionBar(
                            count: pinned.length,
                            index: index,
                            color: scheme.primary,
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pinned.length > 1
                                      ? 'Pinned message #${pinned.length - index}'
                                      : 'Pinned message',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  messagePreview(message).text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          if (widget.onUnpin != null)
                            IconButton(
                              tooltip: 'Unpin',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => widget.onUnpin!(message),
                              icon: Icon(
                                Icons.close_rounded,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _PositionBar extends StatelessWidget {
  const _PositionBar({
    required this.count,
    required this.index,
    required this.color,
  });

  final int count;
  final int index;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final segments = count.clamp(1, 4);
    final active = index % segments;
    return SizedBox(
      width: 3,
      height: 36,
      child: Column(
        spacing: 2,
        children: [
          for (var i = 0; i < segments; i++)
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: i == active ? color : color.withValues(alpha: .3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
