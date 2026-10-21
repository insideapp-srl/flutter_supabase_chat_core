import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;

import '../util.dart';
import 'chat_room.dart';
import 'chat_user.dart';
import 'room_channel.dart';
import 'supabase_chat_core.dart';
import 'supabase_chat_core_exception.dart';

/// A Supabase-backed `flutter_chat_core` [core.ChatController].
///
/// Instantiate one [SupabaseChatController] per open room and pass it
/// directly to `Chat.chatController`. Internally it keeps an
/// [core.InMemoryChatController] in sync with the room's private Supabase
/// Realtime channel (message `INSERT`/`UPDATE`/`DELETE` events broadcast by
/// the database), so the UI gets the animated insert/update/remove behavior
/// `flutter_chat_ui` expects.
///
/// On top of that it handles:
///   - cursor-based pagination ([loadPreviousMessages], [hasMoreMessages]);
///   - optimistic sends ([sendMessage]) with automatic reconciliation and a
///     failed state you can [retryMessage];
///   - read receipts ([markAsRead], automatic by default);
///   - reactions ([toggleReaction]) and edits ([editTextMessage]);
///   - pinned messages ([pinnedMessages], [setPinned]);
///   - replies ([resolveMessage]) and jumping to any message, loading older
///     pages as needed ([jumpToMessage]);
///   - the room's typing indicator ([onTyping], [endTyping],
///     [typingUsers]).
class SupabaseChatController
    with core.ScrollToMessageMixin
    implements core.ChatController {
  /// Creates a controller for [room] and starts loading its latest
  /// [pageSize] messages.
  ///
  /// [onError] is called when a background operation (initial load,
  /// realtime processing, automatic mark-as-read) fails — those aren't
  /// awaited by any caller, so this is the only way to observe their
  /// failures. Calls you await directly (e.g. [loadPreviousMessages]) throw
  /// normally instead.
  ///
  /// With [autoMarkAsRead] (default) the room is marked as read once the
  /// first page is loaded and whenever another member's message arrives
  /// while the controller is alive. Pass `false` to call [markAsRead]
  /// yourself (e.g. only while the app is in the foreground).
  ///
  /// [chatCore] defaults to [SupabaseChatCore.instance].
  SupabaseChatController({
    required ChatRoom room,
    this.pageSize = 20,
    this.onError,
    this.autoMarkAsRead = true,
    SupabaseChatCore? chatCore,
  }) : _room = room,
       _chatCore = chatCore ?? SupabaseChatCore.instance {
    _channel = _chatCore.roomChannel(room.id)
      ..addMessageListener(_onMessageChange, onError: _onChannelError)
      ..addTypingListener(_onTypingChanged);
    _initialLoad = _loadInitialMessages();
    unawaited(_loadPinned());
  }

  final ChatRoom _room;
  final SupabaseChatCore _chatCore;
  final core.InMemoryChatController _inner = core.InMemoryChatController();

  /// Number of messages loaded per page.
  final int pageSize;

  /// Whether the room is marked as read automatically (see constructor).
  final bool autoMarkAsRead;

  /// Called when a background operation fails. See the constructor doc.
  final void Function(SupabaseChatCoreException error)? onError;

  late final RoomChannel _channel;
  late final Future<void> _initialLoad;
  final _typingController = StreamController<List<ChatUser>>.broadcast();
  List<ChatUser> _typingUsers = const [];
  bool _hasMoreMessages = true;
  bool _loadingPrevious = false;
  bool _disposed = false;
  Timer? _markAsReadTimer;
  final Map<String, core.Message> _resolved = {};

  /// Pinned messages of the room, newest first, kept up to date in real
  /// time (e.g. for a "pinned message" banner).
  final ValueNotifier<List<core.Message>> pinnedMessages = ValueNotifier(
    const [],
  );

  /// The room this controller works on.
  ChatRoom get room => _room;

  /// Completes when the first page of messages is loaded (or failed to load,
  /// see [onError]).
  Future<void> get initialLoad => _initialLoad;

  /// Whether older messages may still be available to
  /// [loadPreviousMessages].
  bool get hasMoreMessages => _hasMoreMessages;

  String? get _currentUserId => _chatCore.loggedUserId;

  void _handleBackgroundError(String operation, Object error, StackTrace st) {
    if (_disposed) return;
    onError?.call(_chatCore.mapError(operation, error, st));
  }

  void _onChannelError(Object error) =>
      _handleBackgroundError('subscribe', error, StackTrace.current);

  void _onMessageChange(
    String operation,
    Map<String, dynamic> record,
    Map<String, dynamic> oldRecord,
  ) {
    switch (operation) {
      case 'INSERT':
        _onUpsert(record, isInsert: true);
      case 'UPDATE':
        _onUpsert(record, isInsert: false);
      case 'DELETE':
        _onDelete(oldRecord);
    }
  }

  core.Message? _findById(String id) {
    for (final m in _inner.messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  static DateTime _timeOf(core.Message m) =>
      m.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static List<core.Message> _ascending(Iterable<core.Message> messages) =>
      messages.toList()..sort((a, b) => _timeOf(a).compareTo(_timeOf(b)));

  Future<void> _loadInitialMessages() async {
    try {
      final page = await _chatCore.messages(_room.id, limit: pageSize);
      if (_disposed) return;
      _hasMoreMessages = page.length >= pageSize;
      // Realtime may already have delivered (newer) messages while the page
      // was loading: keep them.
      final loadedIds = page.map((m) => m.id).toSet();
      final arrived = _inner.messages.where((m) => !loadedIds.contains(m.id));
      await _inner.setMessages(_ascending([...page, ...arrived]));
      if (autoMarkAsRead) _scheduleMarkAsRead(Duration.zero);
    } catch (e, st) {
      _handleBackgroundError('loadInitialMessages', e, st);
    }
  }

  Future<void> _loadPinned() async {
    try {
      final pinned = await _chatCore.pinnedMessages(_room.id);
      if (!_disposed) pinnedMessages.value = pinned;
    } catch (e, st) {
      _handleBackgroundError('loadPinnedMessages', e, st);
    }
  }

  void _trackPinned(core.Message message, {bool removed = false}) {
    final others = pinnedMessages.value.where((m) => m.id != message.id);
    final pinned = !removed && message.pinned == true;
    final changed = pinned || pinnedMessages.value.length != others.length;
    if (!changed) return;
    final next = [...others, if (pinned) message]
      ..sort((a, b) => _timeOf(b).compareTo(_timeOf(a)));
    pinnedMessages.value = next;
  }

  Future<void> _insertSorted(core.Message message) async {
    final messages = _inner.messages;
    var index = messages.length;
    while (index > 0 &&
        _timeOf(messages[index - 1]).isAfter(_timeOf(message))) {
      index--;
    }
    await _inner.insertMessage(message, index: index);
  }

  Future<void> _onUpsert(
    Map<String, dynamic> row, {
    required bool isInsert,
  }) async {
    if (_disposed) return;
    try {
      final message = messageFromRow(row);
      _trackPinned(message);
      if (_resolved.containsKey(message.id)) _resolved[message.id] = message;
      final old = _findById(message.id);
      if (old != null) {
        // Includes the Realtime echo of our own optimistic send: replace the
        // local "sending" copy with the stored one (status, server fields).
        await _inner.updateMessage(old, message);
      } else if (isInsert) {
        await _insertSorted(message);
        if (autoMarkAsRead && message.authorId != _currentUserId) {
          _scheduleMarkAsRead(const Duration(milliseconds: 800));
        }
      }
    } catch (e, st) {
      _handleBackgroundError(isInsert ? 'onInsert' : 'onUpdate', e, st);
    }
  }

  Future<void> _onDelete(Map<String, dynamic> row) async {
    if (_disposed) return;
    try {
      final id = row['id'];
      if (id == null) return;
      final old = _findById(id.toString());
      _resolved.remove(id.toString());
      final pinned = pinnedMessages.value.where((m) => m.id == id.toString());
      if (pinned.isNotEmpty) _trackPinned(pinned.first, removed: true);
      if (old != null) await _inner.removeMessage(old);
    } catch (e, st) {
      _handleBackgroundError('onDelete', e, st);
    }
  }

  /// Loads the next (older) page of messages and prepends it to
  /// [messages]. Call this e.g. from `ChatAnimatedList.onEndReached`.
  /// No-op when [hasMoreMessages] is false or a load is already running.
  Future<void> loadPreviousMessages() async {
    await _initialLoad;
    if (!_hasMoreMessages || _loadingPrevious || _disposed) return;
    _loadingPrevious = true;
    try {
      final persisted = _inner.messages.where(
        (m) => m.status != core.MessageStatus.sending,
      );
      final oldest = persisted.isEmpty ? null : persisted.first.createdAt;
      final page = await _chatCore.messages(
        _room.id,
        before: oldest,
        limit: pageSize,
      );
      if (_disposed) return;
      _hasMoreMessages = page.length >= pageSize;
      final fresh = page.where((m) => _findById(m.id) == null);
      if (fresh.isNotEmpty) {
        await _inner.insertAllMessages(_ascending(fresh), index: 0);
      }
    } finally {
      _loadingPrevious = false;
    }
  }

  /// Returns message [messageId] of this room: from the loaded messages
  /// when there, otherwise fetched once (and cached) — e.g. to render the
  /// message a reply quotes ([core.Message.replyToMessageId]).
  Future<core.Message?> resolveMessage(String messageId) async {
    final local = _findById(messageId) ?? _resolved[messageId];
    if (local != null) return local;
    final fetched = await _chatCore.message(_room.id, messageId);
    if (fetched != null) _resolved[messageId] = fetched;
    return fetched;
  }

  /// Scrolls to message [messageId], loading older pages until it is found
  /// (at most [maxPages] of them). Returns whether it was found. Needs the
  /// controller to be attached to a `ChatAnimatedList` (it is when passed to
  /// `Chat`).
  Future<bool> jumpToMessage(String messageId, {int maxPages = 20}) async {
    await _initialLoad;
    var pages = 0;
    while (_findById(messageId) == null &&
        _hasMoreMessages &&
        pages < maxPages) {
      await loadPreviousMessages();
      pages++;
    }
    if (_findById(messageId) == null) return false;
    // Let the list lay out the newly inserted pages first.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await scrollToMessage(
      messageId,
      alignment: .5,
      duration: const Duration(milliseconds: 350),
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Typing indicator
  // ---------------------------------------------------------------------------

  void _onTypingChanged(Set<String> ids) {
    if (_disposed) return;
    final me = _currentUserId;
    _typingUsers = _room.users
        .where((u) => ids.contains(u.id) && u.id != me)
        .toList(growable: false);
    _typingController.add(_typingUsers);
  }

  /// Members (other than the logged-in user) currently typing in this room.
  List<ChatUser> get currentTypingUsers => _typingUsers;

  /// Stream of the members (other than the logged-in user) currently typing
  /// in this room. Emits the current list first.
  Stream<List<ChatUser>> get typingUsers => Stream.multi((listener) {
    listener.add(_typingUsers);
    final sub = _typingController.stream.listen(listener.add);
    listener.onCancel = sub.cancel;
  });

  /// Call on every keystroke in the composer. Throttled internally, see
  /// issue #38: typing state travels over Realtime Broadcast, not Presence.
  void onTyping() {
    final uid = _currentUserId;
    if (uid == null || _disposed) return;
    _channel.typing(uid);
  }

  /// Announces that the logged-in user stopped typing (called automatically
  /// by [sendMessage]).
  Future<void> endTyping() async {
    final uid = _currentUserId;
    if (uid == null || _disposed) return;
    await _channel.stopTyping(uid);
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Sends [message] to this room, inserting it locally right away
  /// (optimistic UI, status `sending`) instead of waiting for Realtime.
  ///
  /// Build [message] with a client-generated id (e.g. `const Uuid().v7()` —
  /// v7 keeps ids roughly time-ordered, same as the database's own default).
  /// Supabase stores that exact id, so when the insert comes back over
  /// Realtime the local copy is simply updated with the stored one — no
  /// duplicate. If the request fails, the local copy is kept with status
  /// `error` (see [retryMessage]) and the error is rethrown.
  Future<void> sendMessage(core.Message message) async {
    final uid = _currentUserId;
    final local = message.copyWith(
      authorId: uid ?? message.authorId,
      createdAt: message.createdAt ?? DateTime.now().toUtc(),
      status: core.MessageStatus.sending,
    );
    final existing = _findById(local.id);
    if (existing == null) {
      await _inner.insertMessage(local);
    } else {
      await _inner.updateMessage(existing, local);
    }
    unawaited(endTyping());
    try {
      await _chatCore.sendMessage(local, _room.id);
      final sent = _findById(local.id);
      if (sent != null && sent.status == core.MessageStatus.sending) {
        await _inner.updateMessage(
          sent,
          sent.copyWith(status: core.MessageStatus.sent),
        );
      }
    } catch (_) {
      final failed = _findById(local.id);
      if (failed != null && !_disposed) {
        await _inner.updateMessage(
          failed,
          failed.copyWith(
            status: core.MessageStatus.error,
            failedAt: DateTime.now().toUtc(),
          ),
        );
      }
      rethrow;
    }
  }

  /// Sends again a message whose [sendMessage] failed (status `error`).
  Future<void> retryMessage(core.Message message) =>
      sendMessage(message.copyWith(failedAt: null, createdAt: DateTime.now()));

  /// Replaces the text of the logged-in user's text [message].
  Future<void> editTextMessage(core.TextMessage message, String text) async {
    final edited = message.copyWith(
      text: text,
      editedAt: DateTime.now().toUtc(),
      metadata: {...?message.metadata, 'edited': true},
    );
    final old = _findById(message.id);
    if (old != null) await _inner.updateMessage(old, edited);
    try {
      await _chatCore.updateMessage(edited, _room.id);
    } catch (_) {
      final current = _findById(message.id);
      if (current != null && !_disposed) {
        await _inner.updateMessage(current, message);
      }
      rethrow;
    }
  }

  /// Adds or removes the logged-in user's [reaction] on message
  /// [messageId].
  Future<void> toggleReaction(String messageId, String reaction) async {
    final reactions = await _chatCore.toggleReaction(messageId, reaction);
    final old = _findById(messageId);
    if (old != null && !_disposed) {
      await _inner.updateMessage(
        old,
        old.copyWith(reactions: reactions.isEmpty ? null : reactions),
      );
    }
  }

  /// Pins (or unpins) [message] for everyone in the room (either member of
  /// a direct room, or a group admin).
  Future<void> setPinned(core.Message message, {bool pinned = true}) async {
    await _chatCore.setMessagePinned(message.id, pinned: pinned);
    final updated = message.copyWith(pinned: pinned ? true : null);
    _trackPinned(updated);
    final old = _findById(message.id);
    if (old != null && !_disposed) await _inner.updateMessage(old, updated);
  }

  /// Removes a message both from Supabase and from [messages]. A message
  /// that never reached the server (status `error`) is only removed
  /// locally.
  Future<bool> deleteMessage(String messageId) async {
    final local = _findById(messageId);
    if (local != null && local.status == core.MessageStatus.error) {
      await _inner.removeMessage(local);
      return true;
    }
    final result = await _chatCore.deleteMessage(_room.id, messageId);
    if (result) {
      final old = _findById(messageId);
      if (old != null) await _inner.removeMessage(old);
    }
    return result;
  }

  void _scheduleMarkAsRead(Duration delay) {
    _markAsReadTimer?.cancel();
    _markAsReadTimer = Timer(delay, () async {
      try {
        await markAsRead();
      } catch (e, st) {
        _handleBackgroundError('markAsRead', e, st);
      }
    });
  }

  /// Marks every message of this room as read by the logged-in user (see
  /// `SupabaseChatCore.markRoomAsRead`).
  Future<void> markAsRead() async {
    if (_disposed) return;
    await _chatCore.markRoomAsRead(_room.id);
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
    if (_disposed) return;
    _disposed = true;
    _markAsReadTimer?.cancel();
    unawaited(_channel.removeTypingListener(_onTypingChanged));
    unawaited(
      _channel.removeMessageListener(
        _onMessageChange,
        onError: _onChannelError,
      ),
    );
    unawaited(_typingController.close());
    pinnedMessages.dispose();
    _inner.dispose();
  }
}
