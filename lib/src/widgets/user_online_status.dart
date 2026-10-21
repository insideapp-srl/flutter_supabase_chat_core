import 'package:flutter/material.dart';

import '../class/supabase_chat_core.dart';
import '../class/user_online_status.dart';

/// Rebuilds with the online/offline status of user [uid].
class UserOnlineStatusWidget extends StatefulWidget {
  /// Creates the widget. [chatCore] defaults to
  /// [SupabaseChatCore.instance].
  const UserOnlineStatusWidget({
    super.key,
    required this.uid,
    required this.builder,
    this.chatCore,
  });

  /// Id of the observed user.
  final String uid;

  /// Called with the current status, and again on every change.
  final Widget Function(UserOnlineStatus status) builder;

  /// Chat core used to observe the status.
  final SupabaseChatCore? chatCore;

  @override
  State<UserOnlineStatusWidget> createState() => _UserOnlineStatusWidgetState();
}

class _UserOnlineStatusWidgetState extends State<UserOnlineStatusWidget> {
  late Stream<UserOnlineStatus> _stream;

  Stream<UserOnlineStatus> _createStream() =>
      (widget.chatCore ?? SupabaseChatCore.instance).userOnlineStatus(
        widget.uid,
      );

  @override
  void initState() {
    super.initState();
    // Created once, not in build: every subscription opens (or shares) a
    // Realtime channel.
    _stream = _createStream();
  }

  @override
  void didUpdateWidget(UserOnlineStatusWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid || oldWidget.chatCore != widget.chatCore) {
      _stream = _createStream();
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<UserOnlineStatus>(
    stream: _stream,
    initialData: UserOnlineStatus.offline,
    builder: (context, snapshot) =>
        widget.builder(snapshot.data ?? UserOnlineStatus.offline),
  );
}
