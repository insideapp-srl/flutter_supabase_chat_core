import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../class/message_status_ex.dart';
import '../util.dart';

class RoomTile extends StatelessWidget {
  final ChatRoom room;
  final ValueChanged<ChatRoom> onTap;

  const RoomTile({super.key, required this.room, required this.onTap});

  Widget _buildAvatar(ChatRoom room) {
    final color = getAvatarColor(room.id);
    var otherUserIndex = -1;
    ChatUser? otherUser;

    if (room.type == ChatRoomType.direct) {
      otherUserIndex = room.users.indexWhere(
        (u) => u.id != SupabaseChatCore.instance.loggedSupabaseUser!.id,
      );
      if (otherUserIndex >= 0) {
        otherUser = room.users[otherUserIndex];
      }
    }

    final hasImage = room.imageUrl != null;
    final name = room.name ?? '';
    final Widget child = CircleAvatar(
      backgroundColor: hasImage ? Colors.transparent : color,
      backgroundImage: hasImage ? NetworkImage(room.imageUrl!) : null,
      radius: 20,
      child: !hasImage
          ? Text(
              name.isEmpty ? '' : name[0].toUpperCase(),
              style: const TextStyle(color: Colors.white),
            )
          : null,
    );
    if (otherUser == null) {
      return Padding(padding: const EdgeInsets.only(right: 16), child: child);
    }
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: UserOnlineStatusWidget(
        uid: otherUser.id,
        builder: (status) => Stack(
          alignment: Alignment.bottomRight,
          children: [
            child,
            if (status == UserOnlineStatus.online)
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 3, bottom: 3),
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lastMessage = room.lastMessages?.isNotEmpty == true
        ? room.lastMessages!.first
        : null;
    final status = lastMessage?.status;

    return ListTile(
      key: ValueKey(room.id),
      leading: _buildAvatar(room),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(room.name ?? ''),
          if (lastMessage != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  timeago.format(
                    DateTime.now().subtract(
                      Duration(
                        milliseconds:
                            DateTime.now().millisecondsSinceEpoch -
                            (room.updatedAt ?? 0),
                      ),
                    ),
                    locale: 'en_short',
                  ),
                ),
                if (status != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8.0),
                    child: Icon(
                      size: 20,
                      status.icon,
                      color: status == core.MessageStatus.seen
                          ? Colors.lightBlue
                          : null,
                    ),
                  ),
              ],
            ),
        ],
      ),
      subtitle: lastMessage is core.TextMessage
          ? Text(lastMessage.text, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      onTap: () => onTap(room),
    );
  }
}
