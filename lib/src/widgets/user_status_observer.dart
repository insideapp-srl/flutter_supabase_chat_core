import 'package:flutter/material.dart';

import '../class/supabase_chat_core.dart';
import '../class/user_online_status.dart';
import 'user_status_detector/widgets_binding.dart';

/// This widget takes care of observing the state of the application if it is foregrounded
/// or if it is reduced. At each state change it notifies on the Supabase Realtime channel the state
/// online/offline of the user
class UserOnlineStateObserver extends StatefulWidget {
  /// [child] Child widgets in the widget tree
  final Widget child;

  /// [UserOnlineStateObserver] Widget constructor
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
    super.initState();
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
