import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../theme/app_theme.dart';
import '../utils/format.dart';

/// Quoted message inside a reply bubble (Telegram style: colored bar,
/// author name, one-line preview). Resolves the quoted message through the
/// controller (loaded messages first, fetched otherwise). Tap to jump to it.
class ReplyQuote extends StatefulWidget {
  const ReplyQuote({
    super.key,
    required this.controller,
    required this.room,
    required this.messageId,
    required this.onSurface,
    this.onTap,
  });

  final SupabaseChatController controller;
  final ChatRoom room;
  final String messageId;
  final Color onSurface;
  final VoidCallback? onTap;

  @override
  State<ReplyQuote> createState() => _ReplyQuoteState();
}

class _ReplyQuoteState extends State<ReplyQuote> {
  late final Future<core.Message?> _message = widget.controller.resolveMessage(
    widget.messageId,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<core.Message?>(
    future: _message,
    builder: (context, snapshot) {
      final message = snapshot.data;
      final author = message == null
          ? null
          : widget.room.member(message.authorId);
      final color = author == null
          ? ChatPalette.of(context).accent
          : avatarColor(author.id, Theme.of(context).colorScheme);
      final preview = messagePreview(message);
      return QuoteBlock(
        color: color,
        title: author?.fullName ?? (snapshot.hasData ? 'Deleted message' : '…'),
        text: message == null ? '' : preview.text,
        textColor: widget.onSurface,
        onTap: widget.onTap,
      );
    },
  );
}

/// The visual of a quote: left accent bar on a tinted background.
class QuoteBlock extends StatelessWidget {
  const QuoteBlock({
    super.key,
    required this.color,
    required this.title,
    required this.text,
    required this.textColor,
    this.onTap,
    this.trailing,
  });

  final Color color;
  final String title;
  final String text;
  final Color textColor;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelLarge?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (text.isNotEmpty)
                      Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(color: textColor),
                      ),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
