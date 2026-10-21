import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:meta/meta.dart';
import 'package:mime/mime.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../util.dart';
import 'chat_room.dart';
import 'chat_room_change.dart';
import 'chat_room_role.dart';
import 'chat_room_type.dart';
import 'chat_user.dart';
import 'presence_watch.dart';
import 'room_channel.dart';
import 'supabase_chat_core_config.dart';
import 'supabase_chat_core_exception.dart';
import 'upload_asset_result.dart';
import 'user_online_status.dart';

/// Provides access to Supabase chat data.
///
/// Most apps use the [instance] singleton, bound to `Supabase.instance`.
/// Create your own instance with [SupabaseChatCore.new] to work with a
/// different [SupabaseClient] (e.g. several logged-in users in the same
/// process, as integration tests do) — and [dispose] it when done.
class SupabaseChatCore {
  /// Creates a chat core bound to [client] (defaults to
  /// `Supabase.instance.client`, which must already be initialized).
  SupabaseChatCore({
    SupabaseClient? client,
    SupabaseChatCoreConfig config = const SupabaseChatCoreConfig(),
  }) : _client = client,
       _config = config {
    _authSubscription = this.client.auth.onAuthStateChange.listen(
      (data) => _onAuthStateChange(),
      onError: (Object error, StackTrace st) {
        // Auth stream errors (e.g. a failed token refresh) are surfaced to
        // the app by supabase_flutter itself; here they only mean "no
        // cached user", which the next successful auth event fixes.
        _loggedUser = null;
      },
    );
    if (loggedSupabaseUser != null) _onAuthStateChange();
  }

  /// Singleton instance, bound to `Supabase.instance.client`.
  static final SupabaseChatCore instance = SupabaseChatCore();

  final SupabaseClient? _client;
  SupabaseChatCoreConfig _config;
  late final StreamSubscription<AuthState> _authSubscription;

  /// Gets the [SupabaseClient] this instance works with.
  SupabaseClient get client => _client ?? Supabase.instance.client;

  /// Config to set custom names for tables, views, channels and buckets, and
  /// the optional scoping hooks. See [SupabaseChatCoreConfig].
  SupabaseChatCoreConfig get config => _config;

  /// Replaces the config. See [SupabaseChatCoreConfig].
  void setConfig(SupabaseChatCoreConfig supabaseChatCoreConfig) {
    _config = supabaseChatCoreConfig;
  }

  /// Current logged in user in Supabase. Is updated automatically.
  User? get loggedSupabaseUser => client.auth.currentUser;

  /// Id of the current logged in user, or `null`.
  String? get loggedUserId => loggedSupabaseUser?.id;

  ChatUser? _loggedUser;

  /// Current logged in user's chat profile. Is updated automatically on auth
  /// state changes (and by [updateUser]).
  ChatUser? get loggedUser => _loggedUser;

  String _requireUserId(String operation) {
    final uid = loggedUserId;
    if (uid == null) {
      throw SupabaseChatCoreAuthException(
        '$operation requires a logged-in user',
      );
    }
    return uid;
  }

  // ---------------------------------------------------------------------------
  // Auth / presence
  // ---------------------------------------------------------------------------

  String? _presenceUserId;
  RealtimeChannel? _ownPresenceChannel;
  bool _ownPresenceSubscribed = false;
  UserOnlineStatus _lastOnlineStatus = UserOnlineStatus.offline;
  final _ownStatusController = StreamController<UserOnlineStatus>.broadcast();

  Future<void> _onAuthStateChange() async {
    final uid = loggedUserId;
    if (uid != _presenceUserId) {
      await _stopOwnPresence();
      if (uid != null) _startOwnPresence(uid);
    }
    if (uid == null) {
      _loggedUser = null;
      return;
    }
    try {
      _loggedUser = await user(uid: uid);
    } on SupabaseChatCoreException {
      // Auth state changes fire in the background with no caller to
      // report to; fail safe to "no cached user" rather than crashing the
      // listener (the next auth state change, or [refreshLoggedUser],
      // retries).
      _loggedUser = null;
    }
  }

  /// Reloads [loggedUser] from Supabase and returns it.
  Future<ChatUser?> refreshLoggedUser() async {
    final uid = loggedUserId;
    _loggedUser = uid == null ? null : await user(uid: uid);
    return _loggedUser;
  }

  void _startOwnPresence(String uid) {
    _presenceUserId = uid;
    _ownPresenceChannel = client.channel(
      '${config.realtimeOnlineUserPrefixChannel}$uid',
    );
    _ownPresenceChannel!.subscribe((status, error) async {
      _ownPresenceSubscribed = status == RealtimeSubscribeStatus.subscribed;
      if (_ownPresenceSubscribed &&
          _lastOnlineStatus == UserOnlineStatus.online) {
        await _trackOwnPresence();
      }
    });
  }

  Future<void> _stopOwnPresence() async {
    final channel = _ownPresenceChannel;
    _ownPresenceChannel = null;
    _ownPresenceSubscribed = false;
    _presenceUserId = null;
    if (channel != null) await client.removeChannel(channel);
  }

  Future<void> _trackOwnPresence() async {
    await _ownPresenceChannel?.track({
      'uid': _presenceUserId,
      'online_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Publishes the logged-in user's online status (see
  /// `UserOnlineStateObserver`, which calls this on app lifecycle changes).
  ///
  /// Going offline also stores the user's `lastSeen`.
  Future<void> setPresenceStatus(UserOnlineStatus status) async {
    if (_lastOnlineStatus == status) return;
    _lastOnlineStatus = status;
    _ownStatusController.add(status);
    switch (status) {
      case UserOnlineStatus.online:
        if (_ownPresenceSubscribed) await _trackOwnPresence();
      case UserOnlineStatus.offline:
        if (_ownPresenceSubscribed) await _ownPresenceChannel?.untrack();
        final uid = loggedUserId;
        if (uid != null) {
          try {
            await client
                .schema(config.schema)
                .from(config.usersTableName)
                .update({'lastSeen': formatChatDate(DateTime.now())})
                .eq('id', uid);
          } on Object {
            // Best effort: going offline usually happens while the app is
            // being backgrounded, often without connectivity.
          }
        }
    }
  }

  final Map<String, PresenceWatch> _presenceWatches = {};

  /// Returns a stream of the online status of user [uid], over Supabase
  /// Realtime Presence. Emits the current status first. The underlying
  /// channel is shared by all listeners of the same user and closed when the
  /// last one cancels.
  Stream<UserOnlineStatus> userOnlineStatus(String uid) {
    if (uid == loggedUserId) {
      return Stream.multi((listener) {
        listener.add(_lastOnlineStatus);
        final sub = _ownStatusController.stream.listen(listener.add);
        listener.onCancel = sub.cancel;
      });
    }
    return Stream.multi((listener) {
      final watch = _presenceWatches.putIfAbsent(
        uid,
        () => PresenceWatch(
          client: client,
          topic: '${config.realtimeOnlineUserPrefixChannel}$uid',
          uid: uid,
          onEmpty: () => _presenceWatches.remove(uid),
        ),
      );
      watch.addListener(listener);
      listener.onCancel = () => watch.removeListener(listener);
    });
  }

  final Map<String, RoomChannel> _roomChannels = {};

  /// Shared private Broadcast channel of room [roomId] (message changes and
  /// typing indicator). One per room per [SupabaseChatCore], however many
  /// controllers are open on that room: Realtime only allows one join per
  /// topic per connection.
  @internal
  RoomChannel roomChannel(String roomId) => _roomChannels.putIfAbsent(
    roomId,
    () => RoomChannel(
      client: client,
      topic: '${config.realtimeRoomChannelPrefix}$roomId',
      onEmpty: () => _roomChannels.remove(roomId),
    ),
  );

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------

  /// Returns the authenticated URL of an object [path] in [bucket] (defaults
  /// to the chat assets bucket).
  String getAssetUrl(String path, {String? bucket}) =>
      '${client.storage.url}/object/authenticated/${bucket ?? config.chatAssetsBucket}/$path';

  /// Returns a unique object path for [assetName] inside [room]'s folder.
  String generateRoomAssetPath(ChatRoom room, String assetName) =>
      '${room.id}/${const Uuid().v7()}-${_safeFileName(assetName)}';

  static String _safeFileName(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// Uploads an attachment to [room]'s folder in the chat assets bucket and
  /// returns its URL and detected MIME type.
  Future<UploadAssetResult> uploadAsset(
    ChatRoom room,
    String assetName,
    Uint8List bytes,
  ) => _guard('uploadAsset', () async {
    final mimeType = lookupMimeType(assetName, headerBytes: bytes);
    final path = generateRoomAssetPath(room, assetName);
    await client.storage
        .from(config.chatAssetsBucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mimeType),
        );
    return UploadAssetResult(
      url: getAssetUrl(path),
      mimeType: mimeType,
      path: path,
    );
  });

  /// Uploads [bytes] as the logged-in user's avatar, stores its URL on the
  /// user's profile and returns the upload result.
  Future<UploadAssetResult> uploadUserAvatar(
    String fileName,
    Uint8List bytes,
  ) async {
    final uid = _requireUserId('uploadUserAvatar');
    return _guard('uploadUserAvatar', () async {
      final mimeType = lookupMimeType(fileName, headerBytes: bytes);
      final path = '$uid/${const Uuid().v7()}-${_safeFileName(fileName)}';
      await client.storage
          .from(config.userAvatarsBucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: mimeType),
          );
      final url = getAssetUrl(path, bucket: config.userAvatarsBucket);
      await client
          .schema(config.schema)
          .from(config.usersTableName)
          .update({
            'imageUrl': url,
            'updatedAt': formatChatDate(DateTime.now()),
          })
          .eq('id', uid);
      _loggedUser = _loggedUser?.copyWith(imageUrl: url);
      return UploadAssetResult(url: url, mimeType: mimeType, path: path);
    });
  }

  /// Headers authenticating HTTP requests to Supabase (e.g. to load
  /// attachments from [getAssetUrl] URLs with `Image.network` or `http`).
  Map<String, String> get httpSupabaseHeaders => {
    'Authorization': 'Bearer ${client.auth.currentSession?.accessToken}',
  };

  // ---------------------------------------------------------------------------
  // Errors
  // ---------------------------------------------------------------------------

  /// Wraps whatever the Supabase client throws for [operation] into the
  /// matching [SupabaseChatCoreException] subtype, so callers only need to
  /// catch one type instead of every possible Supabase exception.
  @internal
  SupabaseChatCoreException mapError(
    String operation,
    Object error,
    StackTrace stackTrace,
  ) {
    if (error is SupabaseChatCoreException) return error;
    if (error is AuthException) {
      return SupabaseChatCoreAuthException(
        '$operation failed',
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (error is StorageException) {
      return SupabaseChatCoreStorageException(
        '$operation failed',
        cause: error,
        stackTrace: stackTrace,
      );
    }
    return SupabaseChatCoreRequestException(
      '$operation failed',
      cause: error,
      stackTrace: stackTrace,
    );
  }

  /// Runs [body], rethrowing any error it throws as the matching
  /// [SupabaseChatCoreException] subtype (see [mapError]).
  Future<T> _guard<T>(String operation, Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      throw mapError(operation, e, st);
    }
  }

  // ---------------------------------------------------------------------------
  // Rooms
  // ---------------------------------------------------------------------------

  Map<String, dynamic>? _roomMetadata(Map<String, dynamic>? metadata) {
    final defaults = config.defaultRoomMetadata?.call();
    if (defaults == null || defaults.isEmpty) return metadata;
    return {...defaults, ...?metadata};
  }

  Future<String> _createRoom({
    required ChatRoomType type,
    required List<String> userIds,
    String? name,
    String? imageUrl,
    Map<String, dynamic>? metadata,
    ChatRoomRole? creatorRole,
  }) async {
    final id = await client
        .schema(config.schema)
        .rpc<dynamic>(
          'create_room',
          params: {
            'p_type': type.name,
            'p_user_ids': userIds,
            'p_name': name,
            'p_image_url': imageUrl,
            'p_metadata': _roomMetadata(metadata),
            'p_creator_role': creatorRole?.name,
          },
        );
    return id.toString();
  }

  Future<ChatRoom> _loadCreatedRoom(String operation, String roomId) async {
    final room = await getRoom(roomId);
    if (room == null) {
      throw SupabaseChatCoreRequestException(
        '$operation: room $roomId was created but cannot be read back',
      );
    }
    return room;
  }

  /// Creates a group room with [users] (the logged-in user is added
  /// automatically with [creatorRole]). [name] is the group name, [imageUrl]
  /// an optional avatar and [metadata] any additional custom data (merged
  /// over [SupabaseChatCoreConfig.defaultRoomMetadata]).
  Future<ChatRoom> createGroupRoom({
    ChatRoomRole creatorRole = ChatRoomRole.admin,
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<ChatUser> users,
  }) async {
    _requireUserId('createGroupRoom');
    return _guard('createGroupRoom', () async {
      final roomId = await _createRoom(
        type: ChatRoomType.group,
        userIds: users.map((u) => u.id).toList(),
        name: name,
        imageUrl: imageUrl,
        metadata: metadata,
        creatorRole: creatorRole,
      );
      return _loadCreatedRoom('createGroupRoom', roomId);
    });
  }

  /// Returns the direct (1-to-1) room with [otherUser], creating it if it
  /// doesn't exist yet. Add [metadata] for any additional custom data (merged
  /// over [SupabaseChatCoreConfig.defaultRoomMetadata]): an existing direct
  /// room is only reused when its metadata contains every entry of it.
  Future<ChatRoom> createRoom(
    ChatUser otherUser, {
    Map<String, dynamic>? metadata,
  }) async {
    final uid = _requireUserId('createRoom');
    if (otherUser.id == uid) {
      throw const SupabaseChatCoreRequestException(
        'createRoom: cannot create a direct room with yourself',
      );
    }
    return _guard('createRoom', () async {
      final roomId = await _createRoom(
        type: ChatRoomType.direct,
        userIds: [otherUser.id],
        metadata: metadata,
      );
      return _loadCreatedRoom('createRoom', roomId);
    });
  }

  /// Updates [room]'s name, avatar and metadata (group rooms: admins only;
  /// direct rooms: metadata only). Membership is managed with [addMembers],
  /// [removeMember], [leaveRoom] and [setMemberRole].
  Future<void> updateRoom(ChatRoom room) async {
    _requireUserId('updateRoom');
    return _guard('updateRoom', () async {
      final isDirect = room.type == ChatRoomType.direct;
      await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .update({
            if (!isDirect) 'imageUrl': room.imageUrl,
            if (!isDirect) 'name': room.name,
            'metadata': room.metadata,
            'updatedAt': formatChatDate(DateTime.now()),
          })
          .eq('id', room.id);
    });
  }

  /// Adds [userIds] to the group room [roomId] (admins only), with an
  /// optional [role].
  Future<void> addMembers(
    String roomId,
    List<String> userIds, {
    ChatRoomRole? role,
  }) async {
    _requireUserId('addMembers');
    if (userIds.isEmpty) return;
    return _guard('addMembers', () async {
      await client
          .schema(config.schema)
          .from(config.roomMembersTableName)
          .upsert(
            [
              for (final userId in userIds)
                {'roomId': roomId, 'userId': userId, 'role': role?.name},
            ],
            onConflict: 'roomId,userId',
            ignoreDuplicates: true,
          );
    });
  }

  /// Removes [userId] from room [roomId] (admins only, or yourself — see
  /// [leaveRoom]). A room left without members is deleted.
  Future<void> removeMember(String roomId, String userId) async {
    _requireUserId('removeMember');
    return _guard('removeMember', () async {
      await client
          .schema(config.schema)
          .from(config.roomMembersTableName)
          .delete()
          .eq('roomId', roomId)
          .eq('userId', userId);
    });
  }

  /// Removes the logged-in user from room [roomId]. A room left without
  /// members is deleted.
  Future<void> leaveRoom(String roomId) =>
      removeMember(roomId, _requireUserId('leaveRoom'));

  /// Sets [userId]'s [role] in room [roomId] (`null` for a plain member).
  /// Admins only.
  Future<void> setMemberRole(
    String roomId,
    String userId,
    ChatRoomRole? role,
  ) async {
    _requireUserId('setMemberRole');
    return _guard('setMemberRole', () async {
      await client
          .schema(config.schema)
          .from(config.roomMembersTableName)
          .update({'role': role?.name})
          .eq('roomId', roomId)
          .eq('userId', userId);
    });
  }

  /// Deletes room [roomId] with all its messages (group rooms: admins only;
  /// direct rooms: either member).
  Future<void> deleteRoom(String roomId) => _guard('deleteRoom', () async {
    await client
        .schema(config.schema)
        .from(config.roomsTableName)
        .delete()
        .eq('id', roomId);
  });

  /// Marks every message of room [roomId] as read by the logged-in user:
  /// resets the room's [ChatRoom.unreadCount] and flips other members'
  /// messages to `seen` (their read receipts).
  Future<void> markRoomAsRead(String roomId) async {
    _requireUserId('markRoomAsRead');
    return _guard('markRoomAsRead', () async {
      await client
          .schema(config.schema)
          .rpc<dynamic>('mark_room_as_read', params: {'p_room_id': roomId});
    });
  }

  /// Pins (or unpins) room [roomId] on top of the logged-in user's rooms
  /// list. Only affects the logged-in user.
  Future<void> pinRoom(String roomId, {bool pinned = true}) async {
    _requireUserId('pinRoom');
    return _guard('pinRoom', () async {
      await client
          .schema(config.schema)
          .rpc<dynamic>(
            'pin_room',
            params: {'p_room_id': roomId, 'p_pinned': pinned},
          );
    });
  }

  /// Mutes room [roomId] for the logged-in user, for [duration] (for ever
  /// when `null`). Muting is advisory: read [ChatRoom.isMuted] to decide
  /// whether to notify. Only affects the logged-in user.
  Future<void> muteRoom(String roomId, {Duration? duration}) async {
    _requireUserId('muteRoom');
    return _guard('muteRoom', () async {
      await client
          .schema(config.schema)
          .rpc<dynamic>(
            'mute_room',
            params: {
              'p_room_id': roomId,
              'p_until': duration == null
                  ? 'infinity'
                  : formatChatDate(DateTime.now().add(duration)),
            },
          );
    });
  }

  /// Unmutes room [roomId] for the logged-in user.
  Future<void> unmuteRoom(String roomId) async {
    _requireUserId('unmuteRoom');
    return _guard('unmuteRoom', () async {
      await client
          .schema(config.schema)
          .rpc<dynamic>(
            'mute_room',
            params: {'p_room_id': roomId, 'p_until': null},
          );
    });
  }

  /// Returns room [roomId], or `null` if it doesn't exist or the logged-in
  /// user isn't a member.
  Future<ChatRoom?> getRoom(String roomId) async {
    final uid = loggedUserId;
    if (uid == null) return null;
    return _guard('getRoom', () async {
      final rows = await client
          .schema(config.schema)
          .from(config.roomsViewName)
          .select()
          .eq('id', roomId)
          .limit(1);
      return rows.isEmpty
          ? null
          : ChatRoom.fromJson(rows.first, currentUserId: uid);
    });
  }

  /// Returns a stream of room [roomId]: emits it right away, then again on
  /// every change to the room or its members. Completes when the room is
  /// deleted or the logged-in user leaves it.
  Stream<ChatRoom> room(String roomId) {
    final uid = loggedUserId;
    if (uid == null) return const Stream.empty();

    late final StreamController<ChatRoom> controller;
    RealtimeChannel? channel;
    var refreshing = Future<void>.value();

    Future<void> refresh() => refreshing = refreshing.then((_) async {
      if (controller.isClosed) return;
      try {
        final room = await getRoom(roomId);
        if (controller.isClosed) return;
        if (room == null) {
          await controller.close();
        } else {
          controller.add(room);
        }
      } on SupabaseChatCoreException catch (e) {
        if (!controller.isClosed) controller.addError(e);
      }
    });

    controller = StreamController<ChatRoom>(
      onListen: () {
        channel = client
            .channel(_uniqueTopic('${config.schema}:room:$roomId'))
            .onPostgresChanges(
              event: PostgresChangeEvent.update,
              schema: config.schema,
              table: config.roomsTableName,
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'id',
                value: roomId,
              ),
              callback: (_) => refresh(),
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.insert,
              schema: config.schema,
              table: config.roomMembersTableName,
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'roomId',
                value: roomId,
              ),
              callback: (_) => refresh(),
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.update,
              schema: config.schema,
              table: config.roomMembersTableName,
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'roomId',
                value: roomId,
              ),
              callback: (_) => refresh(),
            )
            // DELETE events can't be filtered (Realtime only ships the old
            // row's primary key for them): refetch on any, cheap enough.
            .onPostgresChanges(
              event: PostgresChangeEvent.delete,
              schema: config.schema,
              table: config.roomMembersTableName,
              callback: (payload) {
                final old = payload.oldRecord;
                if (old['roomId'] == null || old['roomId'] == roomId) {
                  refresh();
                }
              },
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.delete,
              schema: config.schema,
              table: config.roomsTableName,
              callback: (payload) {
                if (payload.oldRecord['id'] == roomId) refresh();
              },
            )
            .subscribe(
              (status, error) => _reportSubscribeError(controller, status, error),
            );
        refresh();
      },
      onCancel: () async {
        final c = channel;
        channel = null;
        if (c != null) await client.removeChannel(c);
      },
    );
    return controller.stream;
  }

  /// Returns a page of the rooms the logged-in user is a member of: the ones
  /// they pinned first, then most recently updated first. [filter] matches the room name
  /// (case-insensitive; direct rooms are named after the other member).
  /// [SupabaseChatCoreConfig.roomsQueryFilter] is applied too.
  Future<List<ChatRoom>> rooms({
    String? filter,
    int offset = 0,
    int limit = 20,
  }) async {
    final uid = loggedUserId;
    if (uid == null) return const [];
    return _guard('rooms', () async {
      var query = client
          .schema(config.schema)
          .from(config.roomsViewName)
          .select();
      if (filter != null && filter.trim().isNotEmpty) {
        query = query.ilike('name', '%${filter.trim()}%');
      }
      query = config.roomsQueryFilter?.call(query) ?? query;
      final rows = await query
          .order('pinnedAt', ascending: false, nullsFirst: false)
          .order('updatedAt', ascending: false)
          .order('id', ascending: false)
          .range(offset, offset + limit - 1);
      return rows
          .map((row) => ChatRoom.fromJson(row, currentUserId: uid))
          .toList();
    });
  }

  /// Returns a stream of changes to the rooms the logged-in user is a member
  /// of: a [ChatRoomUpserted] when a room is created, updated (e.g. receives
  /// a message) or the user is added to it, a [ChatRoomRemoved] when it is
  /// deleted or the user leaves it. Rooms rejected by
  /// [SupabaseChatCoreConfig.roomFilter] are skipped.
  ///
  /// Merge it into a list with [applyRoomChange], or use
  /// `SupabaseChatRoomsController`, which does it for you.
  Stream<ChatRoomChange> roomsChanges() {
    final uid = loggedUserId;
    if (uid == null) return const Stream.empty();

    late final StreamController<ChatRoomChange> controller;
    RealtimeChannel? channel;
    var queue = Future<void>.value();

    void upsert(String roomId) => queue = queue.then((_) async {
      if (controller.isClosed) return;
      try {
        final room = await getRoom(roomId);
        if (controller.isClosed) return;
        if (room == null) {
          controller.add(ChatRoomRemoved(roomId));
        } else if (config.roomFilter?.call(room) ?? true) {
          controller.add(ChatRoomUpserted(room));
        }
      } on SupabaseChatCoreException catch (e) {
        if (!controller.isClosed) controller.addError(e);
      }
    });

    void remove(String roomId) => queue = queue.then((_) {
      if (!controller.isClosed) controller.add(ChatRoomRemoved(roomId));
    });

    controller = StreamController<ChatRoomChange>(
      onListen: () {
        channel = client
            .channel(_uniqueTopic('${config.schema}:rooms:$uid'))
            .onPostgresChanges(
              event: PostgresChangeEvent.update,
              schema: config.schema,
              table: config.roomsTableName,
              callback: (payload) => upsert(payload.newRecord['id'].toString()),
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.delete,
              schema: config.schema,
              table: config.roomsTableName,
              callback: (payload) {
                final id = payload.oldRecord['id'];
                if (id != null) remove(id.toString());
              },
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.insert,
              schema: config.schema,
              table: config.roomMembersTableName,
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'userId',
                value: uid,
              ),
              callback: (payload) =>
                  upsert(payload.newRecord['roomId'].toString()),
            )
            // Unfilterable (see [room]): the old row only carries the
            // primary key, which does include roomId/userId here.
            .onPostgresChanges(
              event: PostgresChangeEvent.delete,
              schema: config.schema,
              table: config.roomMembersTableName,
              callback: (payload) {
                final old = payload.oldRecord;
                if (old['roomId'] == null) return;
                if (old['userId'] == uid) {
                  remove(old['roomId'].toString());
                } else {
                  upsert(old['roomId'].toString());
                }
              },
            )
            .subscribe(
              (status, error) => _reportSubscribeError(controller, status, error),
            );
      },
      onCancel: () async {
        final c = channel;
        channel = null;
        if (c != null) await client.removeChannel(c);
      },
    );
    return controller.stream;
  }

  /// Applies [change] to [rooms] and returns the resulting list, sorted by
  /// [ChatRoom.updatedAt] (most recent first). When [onlyExisting] is true
  /// an upsert of a room not in [rooms] is ignored (e.g. while a search
  /// filter is active).
  static List<ChatRoom> applyRoomChange(
    List<ChatRoom> rooms,
    ChatRoomChange change, {
    bool onlyExisting = false,
  }) {
    final result = List<ChatRoom>.from(rooms);
    switch (change) {
      case ChatRoomUpserted(:final room):
        final index = result.indexWhere((r) => r.id == room.id);
        if (index >= 0) {
          result[index] = room;
        } else if (!onlyExisting) {
          result.add(room);
        }
      case ChatRoomRemoved(:final roomId):
        result.removeWhere((r) => r.id == roomId);
    }
    result.sort(compareRoomsByUpdatedAt);
    return result;
  }

  /// Sort comparator of rooms lists: rooms pinned by the user first (most
  /// recently pinned first), then most recently updated first, rooms
  /// without an [ChatRoom.updatedAt] last.
  static int compareRoomsByUpdatedAt(ChatRoom a, ChatRoom b) {
    final ap = a.pinnedAt, bp = b.pinnedAt;
    if (ap != null || bp != null) {
      if (ap == null) return 1;
      if (bp == null) return -1;
      return bp.compareTo(ap);
    }
    final au = a.updatedAt, bu = b.updatedAt;
    if (au == null && bu == null) return 0;
    if (au == null) return 1;
    if (bu == null) return -1;
    return bu.compareTo(au);
  }

  /// Surfaces a failed/timed out Realtime subscription on [controller]'s
  /// stream, instead of silently never delivering changes.
  void _reportSubscribeError(
    StreamController<Object> controller,
    RealtimeSubscribeStatus status,
    Object? error,
  ) {
    if (controller.isClosed) return;
    if (status == RealtimeSubscribeStatus.channelError ||
        status == RealtimeSubscribeStatus.timedOut) {
      controller.addError(
        SupabaseChatCoreRequestException(
          'Realtime subscription ${status.name}',
          cause: error,
        ),
      );
    }
  }

  static int _topicCounter = 0;

  /// Postgres changes channels can be named freely: a per-subscription
  /// unique topic lets several listeners of the same data coexist on one
  /// Realtime connection (which allows a single join per topic).
  static String _uniqueTopic(String base) => '$base:${++_topicCounter}';

  // ---------------------------------------------------------------------------
  // Users
  // ---------------------------------------------------------------------------

  /// Returns a page of users, sorted by name. Every word of [filter] must
  /// match the first or last name (case-insensitive). Set
  /// [excludeLoggedUser] to leave the logged-in user out (e.g. in a "start a
  /// conversation" picker). [SupabaseChatCoreConfig.usersQueryFilter] is
  /// applied too.
  Future<List<ChatUser>> users({
    String? filter,
    int offset = 0,
    int limit = 20,
    bool excludeLoggedUser = false,
  }) async {
    final uid = loggedUserId;
    if (uid == null) return const [];
    return _guard('users', () async {
      var query = client
          .schema(config.schema)
          .from(config.usersViewName)
          .select();
      for (final word in (filter ?? '').trim().split(RegExp(r'\s+'))) {
        if (word.isEmpty) continue;
        final value =
            '"%${word.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}%"';
        query = query.or('firstName.ilike.$value,lastName.ilike.$value');
      }
      if (excludeLoggedUser) query = query.neq('id', uid);
      query = config.usersQueryFilter?.call(query) ?? query;
      final rows = await query
          .order('firstName', ascending: true)
          .order('lastName', ascending: true)
          .order('id', ascending: true)
          .range(offset, offset + limit - 1);
      return rows.map(ChatUser.fromJson).toList();
    });
  }

  /// Returns user [uid], or `null` if not found.
  Future<ChatUser?> user({required String uid}) => _guard('user', () async {
    final rows = await client
        .schema(config.schema)
        .from(config.usersViewName)
        .select()
        .eq('id', uid)
        .limit(1);
    return rows.isEmpty ? null : ChatUser.fromJson(rows.first);
  });

  /// Updates the logged-in user's profile (name, avatar, metadata).
  Future<void> updateUser(ChatUser user) => _guard('updateUser', () async {
    await client
        .schema(config.schema)
        .from(config.usersTableName)
        .update({
          'firstName': user.firstName,
          'imageUrl': user.imageUrl,
          'lastName': user.lastName,
          'metadata': user.metadata,
          'updatedAt': formatChatDate(DateTime.now()),
        })
        .eq('id', user.id);
    if (user.id == loggedUserId) {
      _loggedUser = (_loggedUser ?? user).copyWith(
        firstName: user.firstName,
        lastName: user.lastName,
        imageUrl: user.imageUrl,
        metadata: user.metadata,
      );
    }
  });

  // ---------------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------------

  /// Returns up to [limit] messages of room [roomId], newest first, older
  /// than [before] when given (cursor-based pagination: stable while new
  /// messages keep arriving).
  Future<List<core.Message>> messages(
    String roomId, {
    DateTime? before,
    int limit = 20,
  }) => _guard('messages', () async {
    var query = client
        .schema(config.schema)
        .from(config.messagesViewName)
        .select()
        .eq('roomId', roomId);
    if (before != null) {
      query = query.lt('createdAt', formatChatDate(before)!);
    }
    final rows = await query
        .order('createdAt', ascending: false)
        .order('id', ascending: false)
        .limit(limit);
    return rows.map(messageFromRow).toList();
  });

  /// Returns message [messageId] of room [roomId], or `null` if not found
  /// (e.g. to show the message a reply quotes when it isn't loaded).
  Future<core.Message?> message(String roomId, String messageId) =>
      _guard('message', () async {
        final rows = await client
            .schema(config.schema)
            .from(config.messagesViewName)
            .select()
            .eq('roomId', roomId)
            .eq('id', messageId)
            .limit(1);
        return rows.isEmpty ? null : messageFromRow(rows.first);
      });

  /// Returns the pinned messages of room [roomId], newest first.
  Future<List<core.Message>> pinnedMessages(String roomId) =>
      _guard('pinnedMessages', () async {
        final rows = await client
            .schema(config.schema)
            .from(config.messagesViewName)
            .select()
            .eq('roomId', roomId)
            .eq('pinned', true)
            .order('createdAt', ascending: false)
            .limit(50);
        return rows.map(messageFromRow).toList();
      });

  /// Returns up to [limit] text messages of room [roomId] whose text
  /// contains [query] (case-insensitive), newest first.
  Future<List<core.Message>> searchMessages(
    String roomId,
    String query, {
    int limit = 50,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    return _guard('searchMessages', () async {
      final rows = await client
          .schema(config.schema)
          .from(config.messagesViewName)
          .select()
          .eq('roomId', roomId)
          .ilike('text', '%$trimmed%')
          .order('createdAt', ascending: false)
          .limit(limit);
      return rows.map(messageFromRow).toList();
    });
  }

  /// Pins (or unpins) message [messageId] for everyone in its room: either
  /// member of a direct room, or a group admin.
  Future<void> setMessagePinned(String messageId, {bool pinned = true}) async {
    _requireUserId('setMessagePinned');
    return _guard('setMessagePinned', () async {
      await client
          .schema(config.schema)
          .rpc<dynamic>(
            'set_message_pinned',
            params: {'p_message_id': messageId, 'p_pinned': pinned},
          );
    });
  }

  /// Sends [message] to room [roomId]. Build [message] with one of
  /// `flutter_chat_core`'s `Message` factories (`Message.text`,
  /// `Message.image`, ...) and your own `id` (e.g. `const Uuid().v7()`).
  /// `authorId` is always set to the logged-in user, and `createdAt`
  /// defaults to now. Stores [message]'s `id` as-is, so a caller doing
  /// optimistic UI (see `SupabaseChatController.sendMessage`) gets the exact
  /// same row back from Realtime instead of a second, differently-id'd one.
  Future<void> sendMessage(core.Message message, String roomId) async {
    final uid = _requireUserId('sendMessage');
    return _guard('sendMessage', () async {
      final row = messageToRow(message)
        ..['id'] = message.id
        ..['roomId'] = roomId
        ..['authorId'] = uid
        ..['createdAt'] = formatChatDate(message.createdAt ?? DateTime.now());
      await client
          .schema(config.schema)
          .from(config.messagesTableName)
          .insert(row);
    });
  }

  /// Updates [message]'s content and metadata in room [roomId]. Only the
  /// author can update a message. Status, reactions and the pinned flag are
  /// left alone: see [markRoomAsRead], [toggleReaction] and
  /// [setMessagePinned].
  Future<void> updateMessage(core.Message message, String roomId) =>
      _guard('updateMessage', () async {
        final row = messageToRow(message)
          ..remove('status')
          ..remove('reactions')
          ..remove('pinned')
          ..['updatedAt'] = formatChatDate(DateTime.now());
        await client
            .schema(config.schema)
            .from(config.messagesTableName)
            .update(row)
            .eq('roomId', roomId)
            .eq('id', message.id);
      });

  /// Adds the logged-in user's [reaction] (e.g. an emoji) to message
  /// [messageId], or removes it if already there. Returns the message's
  /// updated reactions (reaction → user ids).
  Future<Map<String, List<String>>> toggleReaction(
    String messageId,
    String reaction,
  ) async {
    _requireUserId('toggleReaction');
    return _guard('toggleReaction', () async {
      final result = await client
          .schema(config.schema)
          .rpc<dynamic>(
            'toggle_message_reaction',
            params: {'p_message_id': messageId, 'p_reaction': reaction},
          );
      final map = (result as Map?) ?? const {};
      return {
        for (final entry in map.entries)
          entry.key.toString(): [
            for (final id in (entry.value as List? ?? const [])) id.toString(),
          ],
      };
    });
  }

  /// Deletes message [messageId] of room [roomId] (its author, or a room
  /// admin). Returns whether a message was actually deleted.
  Future<bool> deleteMessage(String roomId, String messageId) =>
      _guard('deleteMessage', () async {
        final result = await client
            .schema(config.schema)
            .from(config.messagesTableName)
            .delete()
            .eq('roomId', roomId)
            .eq('id', messageId)
            .select('id');
        return result.isNotEmpty;
      });

  /// Releases the Realtime channels and listeners held by this instance.
  /// Only needed for instances you created yourself, not for [instance].
  Future<void> dispose() async {
    await _authSubscription.cancel();
    await _stopOwnPresence();
    for (final watch in _presenceWatches.values.toList()) {
      await watch.dispose();
    }
    _presenceWatches.clear();
    for (final channel in _roomChannels.values.toList()) {
      await channel.dispose();
    }
    _roomChannels.clear();
    await _ownStatusController.close();
  }
}
