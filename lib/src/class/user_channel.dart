import 'dart:async';

import 'package:meta/meta.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature of a [UserChannel] listener: room [roomId] changed (updated,
/// a member joined or left, a role changed). [removed] is true when the
/// logged-in user is no longer a member of it (left, removed, or the room
/// was deleted).
typedef RoomChangeListener = void Function(String roomId, bool removed);

/// The logged-in user's private Supabase Realtime **Broadcast** channel
/// (`<prefix><uid>`), shared by every `SupabaseChatCore.roomsChanges` and
/// `SupabaseChatCore.room` stream (Realtime only allows one join per topic
/// per connection).
///
/// The database sends a `room_change` event on it to every member of a room
/// whenever the room or its membership changes (the `chats.send_room_change`
/// trigger function); only the user themselves may join it (RLS policies on
/// `realtime.messages`). Room and membership changes used to travel as
/// Postgres Changes, whose DELETE events Realtime delivers to every
/// subscriber without RLS.
@internal
class UserChannel {
  /// Joins [topic] right away.
  UserChannel({
    required this.client,
    required this.topic,
    required this.onEmpty,
  }) {
    _channel = client.channel(
      topic,
      opts: const RealtimeChannelConfig(private: true),
    );
    _channel.onBroadcast(event: roomChangeEvent, callback: _onRoomChange);
    _channel.subscribe((status, error) {
      if (_disposed) return;
      if (status == RealtimeSubscribeStatus.channelError ||
          status == RealtimeSubscribeStatus.timedOut) {
        for (final listener in _errorListeners.toList()) {
          listener(status, error);
        }
      }
    });
  }

  /// Broadcast event name of room changes.
  static const roomChangeEvent = 'room_change';

  /// Client the channel lives on.
  final SupabaseClient client;

  /// Channel topic (`<prefix><uid>`).
  final String topic;

  /// Called once the last listener is removed, right before the channel is
  /// released.
  final void Function() onEmpty;

  late final RealtimeChannel _channel;
  bool _disposed = false;
  final Set<RoomChangeListener> _listeners = {};
  final Set<void Function(RealtimeSubscribeStatus status, Object? error)>
  _errorListeners = {};

  void _onRoomChange(Map<String, dynamic> message) {
    final payload = message['payload'] is Map
        ? (message['payload'] as Map).cast<String, dynamic>()
        : message;
    final roomId = payload['roomId']?.toString();
    if (roomId == null) return;
    final removed = payload['removed'] == true;
    for (final listener in _listeners.toList()) {
      listener(roomId, removed);
    }
  }

  /// Adds a room change [listener], and an optional [onError] called when
  /// joining the channel fails or times out.
  void addListener(
    RoomChangeListener listener, {
    void Function(RealtimeSubscribeStatus status, Object? error)? onError,
  }) {
    _listeners.add(listener);
    if (onError != null) _errorListeners.add(onError);
  }

  /// Removes [listener] (and its [onError]); releases the channel when it
  /// was the last one.
  Future<void> removeListener(
    RoomChangeListener listener, {
    void Function(RealtimeSubscribeStatus status, Object? error)? onError,
  }) async {
    _listeners.remove(listener);
    if (onError != null) _errorListeners.remove(onError);
    // Already released (e.g. by `SupabaseChatCore.closeSession`).
    if (_disposed || _listeners.isNotEmpty) return;
    // Unregister first, so a channel requested while this one is still
    // shutting down is a fresh one rather than this disposed instance.
    onEmpty();
    await dispose();
  }

  /// Releases the channel.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    _errorListeners.clear();
    await client.removeChannel(_channel);
  }
}
