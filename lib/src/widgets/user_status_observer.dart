import 'dart:async';

import 'package:flutter/material.dart';

import '../class/supabase_chat_core.dart';
import '../class/user_online_status.dart';
import 'user_status_detector/widgets_binding.dart';

/// Publishes the logged-in user's online status over Supabase Realtime
/// Presence, following the app lifecycle: online while the app is in the
/// foreground (or the browser tab is focused), offline otherwise.
///
/// Place it once, high in the widget tree (e.g. around your home page).
class UserOnlineStateObserver extends StatefulWidget {
  /// Creates the observer. [chatCore] defaults to
  /// [SupabaseChatCore.instance].
  const UserOnlineStateObserver({
    super.key,
    required this.child,
    this.chatCore,
  });

  /// Child widget.
  final Widget child;

  /// Chat core whose presence is published.
  final SupabaseChatCore? chatCore;

  @override
  State<UserOnlineStateObserver> createState() =>
      _UserOnlineStateObserverState();
}

class _UserOnlineStateObserverState extends State<UserOnlineStateObserver>
    with WidgetsBindingObserver {
  SupabaseChatCore get _chatCore =>
      widget.chatCore ?? SupabaseChatCore.instance;

  @override
  void initState() {
    super.initState();
    widgetsBinding.addObserver(this);
    // No lifecycle event fires for the initial state: an app that just
    // started is in the foreground.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      unawaited(_chatCore.setPresenceStatus(UserOnlineStatus.online));
    }
  }

  @override
  void dispose() {
    widgetsBinding.removeObserver(this);
    unawaited(_chatCore.setPresenceStatus(UserOnlineStatus.offline));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_chatCore.setPresenceStatus(UserOnlineStatus.online));
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_chatCore.setPresenceStatus(UserOnlineStatus.offline));
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
