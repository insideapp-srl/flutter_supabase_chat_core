import 'package:flutter/material.dart';
import '../../flutter_supabase_chat_core.dart';

/// This widget allows you to observe the online/offline status of a specific user
class UserOnlineStatusWidget extends StatelessWidget {
  /// [uid] of the user to be observed
  final String uid;

  /// [builder] the function that is called at each user state change event
  final Widget Function(UserOnlineStatus status) builder;

  /// [UserOnlineStatusWidget] Constructor
  /// Required [uid] : uid of the user to be observed
  /// Required [builder] : is the function that is called at each user state change event
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
