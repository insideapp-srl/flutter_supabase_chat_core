import 'package:flutter/material.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../class/user_ex.dart';
import '../util.dart';

class UserTile extends StatelessWidget {
  final ChatUser user;
  final ValueChanged<ChatUser> onTap;

  const UserTile({super.key, required this.user, required this.onTap});

  Widget _buildAvatar(ChatUser user) {
    final color = getAvatarColor(user.id);
    final hasImage = user.imageUrl != null;
    final name = user.getUserName();
    return Container(
      margin: const EdgeInsets.only(right: 16),
      child: UserOnlineStatusWidget(
        uid: user.id,
        builder: (status) => Stack(
          alignment: Alignment.bottomRight,
          children: [
            CircleAvatar(
              backgroundColor: hasImage ? Colors.transparent : color,
              backgroundImage: hasImage ? NetworkImage(user.imageUrl!) : null,
              radius: 20,
              child: !hasImage
                  ? Text(
                      name.isEmpty ? '' : name[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white),
                    )
                  : null,
            ),
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
  Widget build(BuildContext context) => ListTile(
    leading: _buildAvatar(user),
    title: Text(user.getUserName()),
    onTap: () => onTap(user),
  );
}
