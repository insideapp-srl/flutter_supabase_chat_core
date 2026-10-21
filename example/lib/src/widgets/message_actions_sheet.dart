import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;

/// What the user picked in [MessageActionsSheet].
sealed class MessageAction {
  const MessageAction();
}

class MessageReact extends MessageAction {
  const MessageReact(this.emoji);
  final String emoji;
}

class MessageReply extends MessageAction {
  const MessageReply();
}

class MessagePin extends MessageAction {
  const MessagePin({required this.pinned});
  final bool pinned;
}

class MessageCopy extends MessageAction {
  const MessageCopy();
}

class MessageEdit extends MessageAction {
  const MessageEdit();
}

class MessageDelete extends MessageAction {
  const MessageDelete();
}

class MessageRetry extends MessageAction {
  const MessageRetry();
}

/// Long-press menu of a message: quick reactions plus contextual actions.
class MessageActionsSheet extends StatelessWidget {
  const MessageActionsSheet({
    super.key,
    required this.message,
    required this.canEdit,
    required this.canDelete,
    required this.canPin,
  });

  static const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  final core.Message message;
  final bool canEdit;
  final bool canDelete;
  final bool canPin;

  static Future<MessageAction?> show(
    BuildContext context, {
    required core.Message message,
    required bool canEdit,
    required bool canDelete,
    required bool canPin,
  }) => showModalBottomSheet<MessageAction>(
    context: context,
    builder: (_) => MessageActionsSheet(
      message: message,
      canEdit: canEdit,
      canDelete: canDelete,
      canPin: canPin,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = message.status == core.MessageStatus.error;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final emoji in quickReactions)
                    InkResponse(
                      radius: 28,
                      onTap: () => Navigator.pop(context, MessageReact(emoji)),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 30),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (failed)
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Retry sending'),
              onTap: () => Navigator.pop(context, const MessageRetry()),
            ),
          if (!failed)
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Reply'),
              onTap: () => Navigator.pop(context, const MessageReply()),
            ),
          if (canPin && !failed)
            ListTile(
              leading: Icon(
                message.pinned == true
                    ? Icons.push_pin_outlined
                    : Icons.push_pin_rounded,
              ),
              title: Text(message.pinned == true ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(
                context,
                MessagePin(pinned: message.pinned != true),
              ),
            ),
          if (message is core.TextMessage)
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy text'),
              onTap: () => Navigator.pop(context, const MessageCopy()),
            ),
          if (canEdit && !failed)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () => Navigator.pop(context, const MessageEdit()),
            ),
          if (canDelete || failed)
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
              title: Text('Delete', style: TextStyle(color: scheme.error)),
              onTap: () => Navigator.pop(context, const MessageDelete()),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
