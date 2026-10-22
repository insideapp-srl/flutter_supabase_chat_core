import 'dart:async';

import 'package:meta/meta.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'user_online_status.dart';

/// Observes one user's Presence channel on behalf of every listener of
/// `SupabaseChatCore.userOnlineStatus` for that user, so N widgets showing
/// the same user's status share a single Realtime channel.
@internal
class PresenceWatch {
  /// Subscribes to [topic] right away.
  PresenceWatch({
    required this.client,
    required this.topic,
    required this.uid,
    required this.onEmpty,
  }) {
    _channel = client.channel(topic)
      ..onPresenceSync((_) => _sync())
      ..subscribe();
  }

  /// Client the channel lives on.
  final SupabaseClient client;

  /// Presence channel topic (`<prefix><uid>`).
  final String topic;

  /// Observed user.
  final String uid;

  /// Called once the last listener is removed, right before the channel is
  /// released.
  final void Function() onEmpty;

  late final RealtimeChannel _channel;
  final Set<MultiStreamController<UserOnlineStatus>> _listeners = {};
  UserOnlineStatus _status = UserOnlineStatus.offline;
  bool _disposed = false;

  void _sync() {
    final online = _channel.presenceState().any(
      (state) => state.presences.any((p) => p.payload['uid'] == uid),
    );
    final status = online ? UserOnlineStatus.online : UserOnlineStatus.offline;
    if (status == _status) return;
    _status = status;
    for (final listener in _listeners.toList()) {
      listener.add(status);
    }
  }

  /// Adds [listener], emitting the current status to it right away.
  void addListener(MultiStreamController<UserOnlineStatus> listener) {
    _listeners.add(listener);
    listener.add(_status);
  }

  /// Removes [listener]; releases the channel when it was the last one.
  Future<void> removeListener(
    MultiStreamController<UserOnlineStatus> listener,
  ) async {
    _listeners.remove(listener);
    // Already released (e.g. by `SupabaseChatCore.closeSession`), which
    // closed every listener.
    if (_disposed) return;
    if (_listeners.isEmpty) {
      // Unregister first, so a watch requested while this one is still
      // shutting down is a fresh one rather than this disposed instance.
      onEmpty();
      await dispose();
    }
  }

  /// Releases the channel.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final listener in _listeners.toList()) {
      // Not awaited: the done event is only delivered once the listener
      // resumes a paused subscription.
      unawaited(listener.close());
    }
    _listeners.clear();
    await client.removeChannel(_channel);
  }
}
