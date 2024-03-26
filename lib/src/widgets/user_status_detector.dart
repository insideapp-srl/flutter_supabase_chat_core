import 'package:flutter/material.dart';

import '../class/supabase_chat_core.dart';
import '../class/user_online_status.dart';
import 'user_status_detector/widgets_binding.dart';

class UserOnlineStateObserver extends StatefulWidget {
  final Widget child;

  const UserOnlineStateObserver({
    super.key,
    required this.child,
  });

  @override
  State<UserOnlineStateObserver> createState() =>
      _UserOnlineStateObserverState();
}

class _UserOnlineStateObserverState extends State<UserOnlineStateObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    widgetsBinding.addObserver(this);
  }

  @override
  void dispose() {
    widgetsBinding.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        SupabaseChatCore.instance.setPresenceStatus(UserOnlineStatus.online);
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        SupabaseChatCore.instance.setPresenceStatus(UserOnlineStatus.offline);
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
