import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_room.dart';
import 'chat_room_change.dart';
import 'supabase_chat_core.dart';
import 'supabase_chat_core_exception.dart';

/// Keeps a paginated, searchable list of the logged-in user's rooms in sync
/// with Supabase Realtime: new rooms appear, rooms receiving messages move to
/// the top (with their unread count and last message updated), deleted or
/// left rooms disappear.
///
/// ```dart
/// final rooms = SupabaseChatRoomsController()..loadFirstPage();
/// ListenableBuilder(
///   listenable: rooms,
///   builder: (context, _) => ListView(
///     children: [for (final room in rooms.rooms) Text(room.name ?? '')],
///   ),
/// );
/// ```
///
/// While a [search] filter is active, Realtime only updates rooms already in
/// the list (a room matching the filter can't be told apart client side).
class SupabaseChatRoomsController extends ChangeNotifier {
  /// Creates a controller. Call [loadFirstPage] to start.
  ///
  /// [chatCore] defaults to [SupabaseChatCore.instance].
  SupabaseChatRoomsController({this.pageSize = 20, SupabaseChatCore? chatCore})
    : _chatCore = chatCore ?? SupabaseChatCore.instance;

  final SupabaseChatCore _chatCore;

  /// Number of rooms loaded per page.
  final int pageSize;

  List<ChatRoom> _rooms = const [];
  String _filter = '';
  bool _isLoading = false;
  bool _hasMore = true;
  SupabaseChatCoreException? _error;
  StreamSubscription<ChatRoomChange>? _changes;
  int _generation = 0;
  bool _disposed = false;

  /// Loaded rooms, most recently updated first.
  List<ChatRoom> get rooms => _rooms;

  /// Current search filter.
  String get filter => _filter;

  /// Whether a page is being loaded.
  bool get isLoading => _isLoading;

  /// Whether more rooms may be available to [loadNextPage].
  bool get hasMore => _hasMore;

  /// The last load error, if any (cleared by the next successful load).
  SupabaseChatCoreException? get error => _error;

  /// Total unread messages across the loaded rooms, muted rooms excluded.
  int get totalUnreadCount => _rooms.fold(
    0,
    (total, room) => room.isMuted ? total : total + room.unreadCount,
  );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _listenToChanges() {
    _changes ??= _chatCore.roomsChanges().listen(
      (change) {
        _rooms = SupabaseChatCore.applyRoomChange(
          _rooms,
          change,
          onlyExisting: _filter.isNotEmpty,
        );
        _notify();
      },
      onError: (Object e) {
        if (e is SupabaseChatCoreException) {
          _error = e;
          _notify();
        }
      },
      // The changes end with the session (or right away when nobody is
      // signed in): the next [loadFirstPage] listens again, for whoever is
      // signed in then.
      onDone: () {
        _changes = null;
        if (_chatCore.loggedUserId == null && _rooms.isNotEmpty) {
          _rooms = const [];
          _notify();
        }
      },
    );
  }

  /// (Re)loads the first page, keeping the current [filter].
  Future<void> loadFirstPage() async {
    _listenToChanges();
    final generation = ++_generation;
    _hasMore = true;
    _isLoading = true;
    _notify();
    try {
      final page = await _chatCore.rooms(
        filter: _filter,
        offset: 0,
        limit: pageSize,
      );
      if (generation != _generation || _disposed) return;
      _rooms = page;
      _hasMore = page.length >= pageSize;
      _error = null;
    } on SupabaseChatCoreException catch (e) {
      if (generation != _generation || _disposed) return;
      _error = e;
    } finally {
      if (generation == _generation) {
        _isLoading = false;
        _notify();
      }
    }
  }

  /// Loads the next page. No-op while loading or when [hasMore] is false.
  Future<void> loadNextPage() async {
    if (_isLoading || !_hasMore) return;
    final generation = _generation;
    _isLoading = true;
    _notify();
    try {
      final page = await _chatCore.rooms(
        filter: _filter,
        offset: _rooms.length,
        limit: pageSize,
      );
      if (generation != _generation || _disposed) return;
      final known = _rooms.map((r) => r.id).toSet();
      _rooms = [..._rooms, ...page.where((r) => !known.contains(r.id))];
      _hasMore = page.length >= pageSize;
      _error = null;
    } on SupabaseChatCoreException catch (e) {
      if (generation != _generation || _disposed) return;
      _error = e;
    } finally {
      if (generation == _generation) {
        _isLoading = false;
        _notify();
      }
    }
  }

  /// Applies a name [filter] (empty for none) and reloads the first page.
  Future<void> search(String filter) {
    _filter = filter.trim();
    return loadFirstPage();
  }

  /// Same as [loadFirstPage], e.g. for pull-to-refresh.
  Future<void> refresh() => loadFirstPage();

  /// Locally resets [room]'s unread count (e.g. right after opening it, so
  /// the badge disappears before the server round trip completes).
  void markLocallyAsRead(String roomId) {
    final index = _rooms.indexWhere((r) => r.id == roomId);
    if (index < 0 || _rooms[index].unreadCount == 0) return;
    _rooms = List.of(_rooms)..[index] = _rooms[index].copyWith(unreadCount: 0);
    _notify();
  }

  /// Pins/unpins [roomId] for the logged-in user, updating the list right
  /// away.
  Future<void> pinRoom(String roomId, {bool pinned = true}) async {
    await _chatCore.pinRoom(roomId, pinned: pinned);
    _updateLocally(
      roomId,
      (room) =>
          room.copyWith(pinnedAt: () => pinned ? DateTime.now().toUtc() : null),
    );
  }

  /// Mutes [roomId] for the logged-in user (for ever when [duration] is
  /// `null`), updating the list right away.
  Future<void> muteRoom(String roomId, {Duration? duration}) async {
    await _chatCore.muteRoom(roomId, duration: duration);
    _updateLocally(
      roomId,
      (room) => room.copyWith(
        mutedUntil: () => duration == null
            ? ChatRoom.mutedForever
            : DateTime.now().toUtc().add(duration),
      ),
    );
  }

  /// Unmutes [roomId] for the logged-in user, updating the list right away.
  Future<void> unmuteRoom(String roomId) async {
    await _chatCore.unmuteRoom(roomId);
    _updateLocally(roomId, (room) => room.copyWith(mutedUntil: () => null));
  }

  void _updateLocally(String roomId, ChatRoom Function(ChatRoom) update) {
    final index = _rooms.indexWhere((r) => r.id == roomId);
    if (index < 0) return;
    _rooms = SupabaseChatCore.applyRoomChange(
      _rooms,
      ChatRoomUpserted(update(_rooms[index])),
    );
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes?.cancel());
    super.dispose();
  }
}
