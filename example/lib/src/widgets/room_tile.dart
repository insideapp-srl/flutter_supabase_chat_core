import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../utils/format.dart';
import 'user_avatar.dart';

/// One conversation in the chats list, Telegram style: avatar (with online
/// dot for direct chats), name (+ muted icon), last message with sender
/// prefix and read ticks, time, and an unread badge — grey when muted — or
/// a pin for pinned chats.
class RoomTile extends StatelessWidget {
  const RoomTile({
    super.key,
    required this.room,
    required this.currentUserId,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final ChatRoom room;
  final String currentUserId;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = room.lastMessage;
    final preview = messagePreview(last);
    final unread = room.unreadCount > 0;
    final mine = last != null && last.authorId == currentUserId;
    // "You: ..." for own messages, "<first name>: ..." in groups.
    final prefix = last == null
        ? null
        : mine
        ? 'You'
        : room.type == ChatRoomType.group
        ? room.member(last.authorId)?.firstName
        : null;

    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: .12)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 12, 7),
          child: Row(
            spacing: 12,
            children: [
              UserAvatar.room(room, currentUserId, size: 54),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Row(
                      spacing: 4,
                      children: [
                        // The name takes the free space, so status and time
                        // always sit on the right edge.
                        Expanded(
                          child: Row(
                            spacing: 4,
                            children: [
                              if (room.type == ChatRoomType.group)
                                Icon(
                                  Icons.group_rounded,
                                  size: 16,
                                  color: scheme.onSurface,
                                ),
                              Flexible(
                                child: Text(
                                  room.name ?? 'Unnamed',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (room.isMuted)
                                Icon(
                                  Icons.volume_off_rounded,
                                  size: 15,
                                  color: scheme.onSurfaceVariant,
                                ),
                            ],
                          ),
                        ),
                        if (mine) _StatusIcon(status: last.status),
                        Text(
                          formatListTime(
                            context,
                            last?.createdAt ?? room.updatedAt,
                          ),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      spacing: 6,
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                if (prefix != null)
                                  TextSpan(
                                    text: '$prefix: ',
                                    style: TextStyle(color: scheme.onSurface),
                                  ),
                                if (preview.icon != null)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 3),
                                      child: Icon(
                                        preview.icon,
                                        size: 15,
                                        color: scheme.primary,
                                      ),
                                    ),
                                  ),
                                TextSpan(text: preview.text),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (unread)
                          _Badge(count: room.unreadCount, muted: room.isMuted)
                        else if (room.isPinned)
                          Transform.rotate(
                            angle: .7,
                            child: Icon(
                              Icons.push_pin_rounded,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.muted});

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? scheme.outline : scheme.primary,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        count >= 100 ? '99+' : '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final core.MessageStatus? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      core.MessageStatus.seen => Icon(
        Icons.done_all_rounded,
        size: 16,
        color: scheme.primary,
      ),
      core.MessageStatus.sending => Icon(
        Icons.schedule_rounded,
        size: 14,
        color: scheme.onSurfaceVariant,
      ),
      core.MessageStatus.error => Icon(
        Icons.error_outline_rounded,
        size: 16,
        color: scheme.error,
      ),
      _ => Icon(Icons.done_rounded, size: 16, color: scheme.primary),
    };
  }
}
