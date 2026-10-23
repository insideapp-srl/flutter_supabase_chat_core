import 'dart:async';

import 'package:meta/meta.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature of a [RoomChannel] typing listener: receives the ids of the
/// users currently typing in the room (never including the local user).
typedef TypingListener = void Function(Set<String> typingUserIds);

/// Signature of a [RoomChannel] message listener, called for every
/// INSERT/UPDATE/DELETE on the room's messages.
typedef MessageChangeListener =
    void Function(
      String operation,
      Map<String, dynamic> record,
      Map<String, dynamic> oldRecord,
    );

/// A room's private Supabase Realtime **Broadcast** channels, shared by every
/// controller open on that room (Realtime only allows one join per topic per
/// connection):
///
///  - `<prefix><roomId>`: **message changes**, sent by the database itself
///    (the `chats.broadcast_message_change` trigger calls
///    `realtime.broadcast_changes`). Postgres Changes can't be used for
///    messages: `chats.messages` is partitioned, and Postgres Changes
///    reports rows under their physical partition, never matching a
///    subscription on the parent table. Clients can't send on it, so every
///    event on it comes from the database;
///  - `<prefix><roomId>:typing`: the **typing indicator**, sent by clients.
///
/// Both channels are private: Realtime authorizes joining (reading) and
/// sending against RLS policies on `realtime.messages`, which only let room
/// members in, and only let them send on the typing channel (see
/// 03_database_policy.sql). A typing event's `uid` is still chosen by the
/// sending member: treat it as display data only.
///
/// ## Typing indicator (issue #38)
///
/// Broadcast instead of Presence: Supabase rate-limits Presence `track()`
/// calls per client (a handful per 30s window) and drops the channel when
/// the limit is exceeded, which a typing indicator updating every few
/// hundred milliseconds hits within seconds. Broadcast messages are cheap,
/// ephemeral and not rate-limited at that scale.
///
/// Protocol, per user: while typing, a `typing` event with `typing: true` at
/// most once every [sendInterval]; a `typing: false` event once the user
/// stops ([stopTyping], or [idleTimeout] after the last keystroke).
/// Receivers drop a user that hasn't sent a `typing: true` within
/// [expiryTimeout], so a lost "stopped" event (app killed, connection lost)
/// can never leave a stale indicator behind.
///
/// Trade-off: Broadcast has no state, so someone opening the room while
/// another user is already typing only sees the indicator from that user's
/// next event (at most [sendInterval] later).
@internal
class RoomChannel {
  /// Joins [topic] right away.
  RoomChannel({
    required this.client,
    required this.topic,
    required this.onEmpty,
    this.sendInterval = const Duration(seconds: 2),
    this.idleTimeout = const Duration(seconds: 3),
    this.expiryTimeout = const Duration(seconds: 5),
  }) {
    _channel = client.channel(
      topic,
      opts: const RealtimeChannelConfig(private: true),
    );
    for (final operation in const ['INSERT', 'UPDATE', 'DELETE']) {
      _channel.onBroadcast(
        event: operation,
        callback: (message) => _onMessageChange(operation, message),
      );
    }
    _channel.subscribe(
      (status, error) => _onStatus(_channel, status, error, (subscribed) {}),
    );
    _typingChannel = client.channel(
      '$topic$typingTopicSuffix',
      opts: const RealtimeChannelConfig(private: true),
    );
    _typingChannel.onBroadcast(event: typingEvent, callback: _onTyping);
    _typingChannel.subscribe(
      (status, error) => _onStatus(
        _typingChannel,
        status,
        error,
        (subscribed) => _subscribed = subscribed,
      ),
    );
  }

  /// Broadcast event name of typing updates.
  static const typingEvent = 'typing';

  /// Suffix of the typing channel topic, appended to [topic].
  static const typingTopicSuffix = ':typing';

  void _onStatus(
    RealtimeChannel channel,
    RealtimeSubscribeStatus status,
    Object? error,
    void Function(bool subscribed) setSubscribed,
  ) {
    // Statuses arriving after the release (e.g. the session was closed
    // while Realtime was re-authorizing the channel) concern nobody.
    if (_disposed) return;
    setSubscribed(status == RealtimeSubscribeStatus.subscribed);
    if (status == RealtimeSubscribeStatus.channelError &&
        '$error'.contains('Unauthorized')) {
      // Not (or no longer) a member: retrying can't succeed, and the client
      // would otherwise keep rejoining with backoff for as long as the
      // connection lives, piling up subscription errors server side.
      _unauthorized = true;
      unawaited(client.removeChannel(channel));
    }
    if (status == RealtimeSubscribeStatus.channelError ||
        status == RealtimeSubscribeStatus.timedOut) {
      _notifyError(error ?? 'Realtime channel $topic: ${status.name}');
    }
  }

  void _notifyError(Object error) {
    for (final listener in _errorListeners.toList()) {
      listener(error);
    }
  }

  /// Client the channel lives on.
  final SupabaseClient client;

  /// Message channel topic (`<prefix><roomId>`); the typing channel is
  /// [topic] + [typingTopicSuffix].
  final String topic;

  /// Called once the last listener is removed, right before the channel is
  /// released.
  final void Function() onEmpty;

  /// Minimum interval between two `typing: true` events from this client.
  final Duration sendInterval;

  /// Inactivity after which this client announces it stopped typing.
  final Duration idleTimeout;

  /// How long a remote user stays "typing" without a fresh event.
  final Duration expiryTimeout;

  late final RealtimeChannel _channel;
  late final RealtimeChannel _typingChannel;
  bool _subscribed = false;
  bool _disposed = false;
  bool _unauthorized = false;
  final Set<TypingListener> _typingListeners = {};
  final Set<MessageChangeListener> _messageListeners = {};
  final Set<void Function(Object error)> _errorListeners = {};
  final Map<String, Timer> _typing = {};

  DateTime? _lastSentAt;
  String? _typingAs;
  Timer? _idleTimer;

  /// Whether the typing channel is currently joined.
  bool get isSubscribed => _subscribed;

  /// Whether Realtime refused the channel, or the user was removed from the
  /// room (see [revoke]). The channels are released and won't be retried.
  bool get isUnauthorized => _unauthorized;

  /// Leaves both channels because the logged-in user is no longer a member
  /// of the room (announced on their user channel), reporting it to the
  /// error listeners. Realtime only authorizes a private channel when it is
  /// joined: without this, an open channel would keep receiving the room's
  /// messages until the next re-authorization.
  Future<void> revoke() async {
    if (_disposed || _unauthorized) return;
    _unauthorized = true;
    _subscribed = false;
    _notifyError('Removed from the room: channel $topic closed');
    await client.removeChannel(_channel);
    await client.removeChannel(_typingChannel);
  }

  /// Ids of the remote users currently typing.
  Set<String> get typingUserIds => Set.unmodifiable(_typing.keys);

  static Map<String, dynamic> _payloadOf(Map<String, dynamic> message) =>
      message['payload'] is Map
      ? (message['payload'] as Map).cast<String, dynamic>()
      : message;

  void _onMessageChange(String operation, Map<String, dynamic> message) {
    final payload = _payloadOf(message);
    final record = (payload['record'] as Map?)?.cast<String, dynamic>();
    final oldRecord = (payload['old_record'] as Map?)?.cast<String, dynamic>();
    for (final listener in _messageListeners.toList()) {
      listener(operation, record ?? const {}, oldRecord ?? const {});
    }
  }

  void _onTyping(Map<String, dynamic> message) {
    final payload = _payloadOf(message);
    final uid = payload['uid']?.toString();
    if (uid == null || uid == _typingAs) return;
    if (payload['typing'] == true) {
      _typing[uid]?.cancel();
      _typing[uid] = Timer(expiryTimeout, () {
        _typing.remove(uid);
        _notifyTyping();
      });
    } else {
      _typing.remove(uid)?.cancel();
    }
    _notifyTyping();
  }

  void _notifyTyping() {
    final ids = typingUserIds;
    for (final listener in _typingListeners.toList()) {
      listener(ids);
    }
  }

  Future<void> _sendTyping(String uid, bool typing) async {
    if (!_subscribed || _disposed) return;
    try {
      await _typingChannel.sendBroadcastMessage(
        event: typingEvent,
        payload: {'uid': uid, 'typing': typing},
      );
    } on Object catch (_) {
      // Typing indicators are best effort: a dropped event is corrected by
      // the next one, or by the receivers' expiry timer.
      return;
    }
  }

  /// Call on every keystroke of user [uid]: throttled to one event every
  /// [sendInterval], and followed by a "stopped" event after [idleTimeout]
  /// of inactivity.
  void typing(String uid) {
    _typingAs = uid;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () => stopTyping(uid));
    final now = DateTime.now();
    final last = _lastSentAt;
    if (last != null && now.difference(last) < sendInterval) return;
    _lastSentAt = now;
    unawaited(_sendTyping(uid, true));
  }

  /// Announces that user [uid] stopped typing (e.g. on message sent). No-op
  /// if it wasn't typing.
  Future<void> stopTyping(String uid) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_lastSentAt == null) return;
    _lastSentAt = null;
    await _sendTyping(uid, false);
  }

  /// Adds a typing [listener], calling it right away with the current state.
  void addTypingListener(TypingListener listener) {
    _typingListeners.add(listener);
    listener(typingUserIds);
  }

  /// Removes a typing [listener]; see [_releaseIfUnused].
  Future<void> removeTypingListener(TypingListener listener) async {
    _typingListeners.remove(listener);
    await _releaseIfUnused();
  }

  /// Adds a message change [listener], and an optional [onError] called
  /// when joining the channel fails (e.g. not authorized).
  void addMessageListener(
    MessageChangeListener listener, {
    void Function(Object error)? onError,
  }) {
    _messageListeners.add(listener);
    if (onError != null) _errorListeners.add(onError);
  }

  /// Removes a message change [listener] (and its [onError]); see
  /// [_releaseIfUnused].
  Future<void> removeMessageListener(
    MessageChangeListener listener, {
    void Function(Object error)? onError,
  }) async {
    _messageListeners.remove(listener);
    if (onError != null) _errorListeners.remove(onError);
    await _releaseIfUnused();
  }

  Future<void> _releaseIfUnused() async {
    // Already released (e.g. by `SupabaseChatCore.closeSession`) before its
    // last listener left.
    if (_disposed) return;
    if (_typingListeners.isNotEmpty || _messageListeners.isNotEmpty) return;
    // Unregister first, so a channel requested while this one is still
    // shutting down is a fresh one rather than this disposed instance.
    onEmpty();
    final uid = _typingAs;
    if (uid != null) await stopTyping(uid);
    await dispose();
  }

  /// Releases the channel and timers.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _idleTimer?.cancel();
    for (final timer in _typing.values) {
      timer.cancel();
    }
    _typing.clear();
    _typingListeners.clear();
    _messageListeners.clear();
    _errorListeners.clear();
    if (!_unauthorized) {
      await client.removeChannel(_channel);
      await client.removeChannel(_typingChannel);
    }
  }
}
