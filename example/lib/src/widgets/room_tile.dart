import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../class/message_status_ex.dart';
import '../util.dart';

class RoomTile extends StatelessWidget {
  final types.Room room;
  final ValueChanged<types.Room> onTap;

  const RoomTile({
    super.key,
    required this.room,
    required this.onTap,
  });

  Widget _buildAvatar(types.Room room) {
    final color = getAvatarColor(room.id);
    var otherUserIndex = -1;
    types.User? otherUser;

    if (room.type == types.RoomType.direct) {
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
      return Padding(
        padding: const EdgeInsets.only(right: 16),
        child: child,
      );
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
                margin: const EdgeInsets.only(
                  right: 3,
                  bottom: 3,
                ),
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white,
                    width: 2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListTile(
        key: ValueKey(room.id),
        leading: _buildAvatar(room),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(room.name ?? ''),
            if (room.lastMessages?.isNotEmpty == true)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    timeago.format(
                      DateTime.now().subtract(
                        Duration(
                          milliseconds: DateTime.now().millisecondsSinceEpoch -
                              (room.updatedAt ?? 0),
                        ),
                      ),
                      locale: 'en_short',
                    ),
                  ),
                  if (room.lastMessages!.first.status != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8.0),
                      child: Icon(
                        size: 20,
                        room.lastMessages!.first.status!.icon,
                        color:
                            room.lastMessages!.first.status == types.Status.seen
                                ? Colors.lightBlue
                                : null,
                      ),
                    ),
                ],
              ),
          ],
        ),
        subtitle: room.lastMessages?.isNotEmpty == true &&
                room.lastMessages!.first is types.TextMessage
            ? Text(
                (room.lastMessages!.first as types.TextMessage).text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        onTap: () => onTap(room),
      );
}
