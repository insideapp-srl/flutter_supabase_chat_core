import 'package:flutter/material.dart';
import '../../flutter_supabase_chat_core.dart';

class UserOnlineStatusWidget extends StatelessWidget {
  final String uid;
  final Widget Function(UserOnlineStatus status) builder;

  const UserOnlineStatusWidget({
    super.key,
    required this.uid,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<UserOnlineStatus>(
        stream: SupabaseChatCore.instance.userOnlineStatus(uid),
        initialData: UserOnlineStatus.offline,
        builder: (context, snapshot) =>
            builder(snapshot.data ?? UserOnlineStatus.offline),
      );
}
