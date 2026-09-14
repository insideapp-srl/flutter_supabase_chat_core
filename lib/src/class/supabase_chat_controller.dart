import 'dart:async';

import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../flutter_supabase_chat_core.dart';

/// A Supabase-backed `flutter_chat_core` [core.ChatController].
///
/// Instantiate one [SupabaseChatController] per open room and pass it
/// directly to `Chat.chatController`. Internally it keeps an
/// [core.InMemoryChatController] in sync with Supabase Realtime
/// (`INSERT`/`UPDATE`/`DELETE` on the messages table), so the UI gets the
/// animated insert/update/remove behavior `flutter_chat_ui` expects.
class SupabaseChatController implements core.ChatController {
  /// [pageSize] defines a room's messages pagination size.
  /// [room] is required, it's the controller's reference to the room.
  /// [onError] is called when a background operation (initial load,
  /// realtime insert/update/delete processing) fails — those aren't awaited
  /// by any caller, so this is the only way to observe their failures.
  /// Calls you await directly (e.g. [loadPreviousMessages]) throw normally
  /// instead.
  SupabaseChatController({
    this.pageSize = 10,
    required ChatRoom room,
    this.onError,
  }) : _room = room {
    _messagesQuery().then((value) => _onInitialData(value)).catchError((
      Object e,
      StackTrace st,
    ) {
      _handleBackgroundError('loadInitialMessages', e, st);
    });

    _messagesChannel = _client
        .channel('${_config.schema}:${_config.messagesTableName}:${_room.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: _config.schema,
          table: _config.messagesTableName,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'roomId',
            value: _room.id,
          ),
          callback: (payload) => _onInsert(payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: _config.schema,
          table: _config.messagesTableName,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'roomId',
            value: _room.id,
          ),
          callback: (payload) => _onUpdate(payload.newRecord),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: _config.schema,
          table: _config.messagesTableName,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'roomId',
            value: _room.id,
          ),
          callback: (payload) => _onDelete(payload.oldRecord),
        )
        .subscribe();

    _typingChannel = _client.channel(
      '${_config.realtimeChatTypingUserPrefixChannel}${_room.id}',
      opts: RealtimeChannelConfig(key: 'typing-state'),
    );
    _typingChannel
        .onPresenceSync((_) {
          final newState = _typingChannel.presenceState();
          var typingUsers = <ChatUser>[];
          final keyIndex = newState.indexWhere((e) => e.key == 'typing-state');
          if (keyIndex >= 0) {
            final users = newState[keyIndex].presences
                .where((e) => e.payload['typing'] == true)
                .map((e) => e.payload['uid'].toString())
                .toList();
            typingUsers = _room.users
                .where(
                  (e) =>
                      users.contains(e.id) &&
                      e.id != SupabaseChatCore.instance.loggedSupabaseUser!.id,
                )
                .toList();
          }
          _typingController.sink.add(typingUsers);
        })
        .subscribe((status, error) {
          _typingChannelSubscribed =
              status == RealtimeSubscribeStatus.subscribed;
        });
  }

  final ChatRoom _room;
  final core.InMemoryChatController _inner = core.InMemoryChatController();
  final int pageSize;

  /// Called when a background operation fails. See the constructor doc.
  final void Function(SupabaseChatCoreException error)? onError;

  void _handleBackgroundError(String operation, Object error, StackTrace st) {
    final chatCoreError = error is SupabaseChatCoreException
        ? error
        : SupabaseChatCoreRequestException(
            '$operation failed',
            cause: error,
            stackTrace: st,
          );
    onError?.call(chatCoreError);
  }

  int _currentPage = 0;
  final _typingController = StreamController<List<ChatUser>>.broadcast();
  late final RealtimeChannel _typingChannel;
  late final RealtimeChannel _messagesChannel;
  bool _typingChannelSubscribed = false;
  Timer? _throttleTimer;
  Timer? _endTypingTimer;

  SupabaseClient get _client => SupabaseChatCore.instance.client;

  SupabaseChatCoreConfig get _config => SupabaseChatCore.instance.config;

  PostgrestTransformBuilder _messagesQuery() => _client
      .schema(_config.schema)
      .from(_config.messagesViewName)
      .select()
      .eq('roomId', _room.id)
      .order('createdAt', ascending: false)
      .range(pageSize * _currentPage, (_currentPage * pageSize) + pageSize);

  core.Message? _findById(String id) {
    for (final m in _inner.messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  List<core.Message> _sortedAscending(List<Map<String, dynamic>> rows) {
    final parsed = rows.map(messageFromRow).toList();
    parsed.sort(
      (a, b) => (a.resolvedTime ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(b.resolvedTime ?? DateTime.fromMillisecondsSinceEpoch(0)),
    );
    return parsed;
  }

  Future<void> _onInitialData(List<Map<String, dynamic>> rows) async {
    await _inner.setMessages(_sortedAscending(rows));
  }

  Future<void> _onInsert(Map<String, dynamic> row) async {
    try {
      final message = messageFromRow(row);
      if (_findById(message.id) != null) return;
      await _inner.insertMessage(message);
    } catch (e, st) {
      _handleBackgroundError('onInsert', e, st);
    }
  }

  Future<void> _onUpdate(Map<String, dynamic> row) async {
    try {
      final message = messageFromRow(row);
      final old = _findById(message.id);
      if (old == null) return;
      await _inner.updateMessage(old, message);
    } catch (e, st) {
      _handleBackgroundError('onUpdate', e, st);
    }
  }

  Future<void> _onDelete(Map<String, dynamic> row) async {
    try {
      final old = _findById(row['id'].toString());
      if (old == null) return;
      await _inner.removeMessage(old);
    } catch (e, st) {
      _handleBackgroundError('onDelete', e, st);
    }
  }

  /// Loads the next (older) page of messages and prepends it to
  /// [messages]. Call this e.g. from `Chat`'s pagination callback.
  Future<void> loadPreviousMessages() async {
    _currentPage += 1;
    try {
      final rows = await _messagesQuery();
      final parsed = _sortedAscending(
        rows,
      ).where((m) => _findById(m.id) == null).toList();
      if (parsed.isNotEmpty) {
        await _inner.insertAllMessages(parsed, index: 0);
      }
    } catch (e, st) {
      throw e is SupabaseChatCoreException
          ? e
          : SupabaseChatCoreRequestException(
              'loadPreviousMessages failed',
              cause: e,
              stackTrace: st,
            );
    }
  }

  /// Returns a stream of typing users from Supabase for this room.
  Stream<List<ChatUser>> get typingUsers => _typingController.stream;

  void onTyping() async {
    if (_typingChannelSubscribed &&
        SupabaseChatCore.instance.loggedSupabaseUser != null) {
      if (_throttleTimer?.isActive ?? false) return;
      _throttleTimer = Timer(Duration(milliseconds: 500), () {});
      _endTypingTimer?.cancel();
      _endTypingTimer = Timer(Duration(seconds: 3), () async {
        await _typingChannel.track(_typingInfo(false));
      });
      await _typingChannel.track(_typingInfo(true));
    }
  }

  Future<void> endTyping() async {
    _endTypingTimer?.cancel();
    await _typingChannel.track(_typingInfo(false));
  }

  Map<String, dynamic> _typingInfo(bool typing) => {
    'uid': SupabaseChatCore.instance.loggedSupabaseUser!.id,
    'timestamp': DateTime.now().toIso8601String(),
    'typing': typing,
  };

  /// Sends [message] to this room, inserting it locally right away
  /// (optimistic UI) instead of waiting for Realtime to echo it back.
  ///
  /// Build [message] with a client-generated id (e.g. `const Uuid().v7()` —
  /// v7 keeps ids roughly time-ordered, same as the database's own default).
  /// Supabase stores that exact id, so when the insert comes back over
  /// Realtime, [_onInsert] recognizes it as already present and skips it —
  /// no duplicate, no extra reconciliation logic needed. If the request
  /// fails, the optimistic message is removed again and the error rethrown.
  Future<void> sendMessage(core.Message message) async {
    await _inner.insertMessage(message);
    try {
      await SupabaseChatCore.instance.sendMessage(message, _room.id);
    } catch (_) {
      final optimistic = _findById(message.id);
      if (optimistic != null) await _inner.removeMessage(optimistic);
      rethrow;
    }
  }

  /// Removes a message both from Supabase and from [messages].
  Future<bool> deleteMessage(String messageId) async {
    final result = await SupabaseChatCore.instance.deleteMessage(
      _room.id,
      messageId,
    );
    if (result) {
      final old = _findById(messageId);
      if (old != null) await _inner.removeMessage(old);
    }
    return result;
  }

  /// Underlying in-memory controller, exposed for advanced use cases not
  /// covered by this class (e.g. upload progress tracking via
  /// `UploadProgressMixin`, or programmatic scrolling via
  /// `ScrollToMessageMixin`).
  core.InMemoryChatController get inMemoryController => _inner;

  // ChatController interface: delegates to [_inner], which Realtime keeps
  // in sync with Supabase.

  @override
  List<core.Message> get messages => _inner.messages;

  @override
  Stream<core.ChatOperation> get operationsStream => _inner.operationsStream;

  @override
  Future<void> insertMessage(core.Message message, {int? index}) =>
      _inner.insertMessage(message, index: index);

  @override
  Future<void> insertAllMessages(List<core.Message> messages, {int? index}) =>
      _inner.insertAllMessages(messages, index: index);

  @override
  Future<void> updateMessage(
    core.Message oldMessage,
    core.Message newMessage,
  ) => _inner.updateMessage(oldMessage, newMessage);

  @override
  Future<void> removeMessage(core.Message message) =>
      _inner.removeMessage(message);

  @override
  Future<void> setMessages(List<core.Message> messages) =>
      _inner.setMessages(messages);

  @override
  void dispose() {
    _typingChannel.untrack();
    _client.removeChannel(_typingChannel);
    _client.removeChannel(_messagesChannel);
    _typingController.close();
    _inner.dispose();
  }
}
