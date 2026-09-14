import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:mime/mime.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../flutter_supabase_chat_core.dart';

/// Provides access to Supabase chat data. Singleton, use
/// SupabaseChatCore.instance to access methods.
class SupabaseChatCore {
  SupabaseChatCore._privateConstructor() {
    Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
      if (loggedSupabaseUser != null) {
        try {
          _loggedUser = await user(uid: loggedSupabaseUser!.id);
        } on SupabaseChatCoreException {
          // Auth state changes fire in the background with no caller to
          // report to; fail safe to "no cached user" rather than crashing
          // the listener (the next auth state change will retry).
          _loggedUser = null;
        }
        if (_currentUserOnlineStatusChannel == null) {
          _currentUserOnlineStatusChannel ??= _getUserOnlineStatusChannel(
            loggedSupabaseUser!.id,
          );
          _currentUserOnlineStatusChannel?.subscribe((status, error) async {
            _userStatusSubscribed =
                status == RealtimeSubscribeStatus.subscribed;
            if (_lastOnlineStatus == UserOnlineStatus.online) {
              await _trackUserStatus();
            } else {
              await _currentUserOnlineStatusChannel?.untrack();
            }
          });
        }
      } else {
        _loggedUser = null;
        await _currentUserOnlineStatusChannel?.unsubscribe();
        _userStatusSubscribed = false;
        _currentUserOnlineStatusChannel = null;
      }
    });
  }

  /// Singleton instance.
  static final SupabaseChatCore instance =
      SupabaseChatCore._privateConstructor();

  /// Config to set custom names for users, room and messages tables. Also
  /// see [SupabaseChatCoreConfig].
  SupabaseChatCoreConfig config = const SupabaseChatCoreConfig(
    'chats',
    'rooms',
    'rooms_l',
    'messages',
    'messages_l',
    'users',
    //online-user-${uid}
    'online-user-',
    //chat-user-typing-${room_id}
    'chat-user-typing-',
    'chats_assets',
  );

  /// Sets custom config to change default names for users, rooms
  /// and messages tables. Also see [SupabaseChatCoreConfig].
  void setConfig(SupabaseChatCoreConfig supabaseChatCoreConfig) {
    config = supabaseChatCoreConfig;
  }

  /// Current logged in user in Supabase. Is update automatically.
  User? get loggedSupabaseUser => Supabase.instance.client.auth.currentUser;

  ChatUser? _loggedUser;

  /// Current logged in user. Is update automatically.
  ChatUser? get loggedUser => _loggedUser;

  RealtimeChannel _getUserOnlineStatusChannel(String uid) =>
      client.channel('${config.realtimeOnlineUserPrefixChannel}$uid');

  UserOnlineStatus _lastOnlineStatus = UserOnlineStatus.offline;

  RealtimeChannel? _currentUserOnlineStatusChannel;

  bool _userStatusSubscribed = false;

  Future<void> _trackUserStatus() async {
    final userStatus = {
      'uid': loggedSupabaseUser?.id,
      'online_at': DateTime.now().toIso8601String(),
    };
    await _currentUserOnlineStatusChannel?.track(userStatus);
  }

  Future<void> setPresenceStatus(UserOnlineStatus status) async {
    _lastOnlineStatus = status;
    switch (status) {
      case UserOnlineStatus.online:
        if (_userStatusSubscribed) {
          await _trackUserStatus();
        }
        break;
      case UserOnlineStatus.offline:
        if (_userStatusSubscribed) {
          await _currentUserOnlineStatusChannel?.untrack();
        }
        break;
    }
  }

  final Map<String, RealtimeChannel> _onlineUserChannels = {};

  UserOnlineStatus _userStatus(List<Presence> presences, String uid) =>
      presences.map((e) => e.payload['uid']).contains(uid)
      ? UserOnlineStatus.online
      : UserOnlineStatus.offline;

  /// Returns a stream of online user state from Supabase Realtime.
  Stream<UserOnlineStatus> userOnlineStatus(String uid) {
    final controller = StreamController<UserOnlineStatus>();
    if (_onlineUserChannels[uid] == null) {
      _onlineUserChannels[uid] = _getUserOnlineStatusChannel(uid);
      _onlineUserChannels[uid]!
          .onPresenceJoin((payload) {
            controller.sink.add(_userStatus(payload.newPresences, uid));
          })
          .onPresenceLeave((payload) {
            controller.sink.add(_userStatus(payload.currentPresences, uid));
          })
          .subscribe();
    }
    return controller.stream;
  }

  /// Returns the URL of an asset path in the bucket
  String getAssetUrl(String path) =>
      '${client.storage.url}/object/authenticated/${config.chatAssetsBucket}/$path';

  /// Returns a path based on the specified room id and asset name
  String generateRoomAssetPath(ChatRoom room, String assetName) =>
      '${room.id}/${const Uuid().v1()}-$assetName';

  /// Allows you to upload an asset to a specific room by returning its URL and mimeType
  Future<UploadAssetResult> uploadAsset(
    ChatRoom room,
    String assetName,
    Uint8List bytes,
  ) => _guard('uploadAsset', () async {
    final mimeType = lookupMimeType(assetName, headerBytes: bytes);
    final path = generateRoomAssetPath(room, assetName);
    await Supabase.instance.client.storage
        .from(SupabaseChatCore.instance.config.chatAssetsBucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mimeType),
        );
    return UploadAssetResult(url: getAssetUrl(path), mimeType: mimeType);
  });

  /// Gets proper [SupabaseClient] instance.
  SupabaseClient get client => Supabase.instance.client;

  /// Return header for authenticate api calls to Supabase
  Map<String, String> get httpSupabaseHeaders => {
    'Authorization': 'Bearer ${client.auth.currentSession?.accessToken}',
  };

  /// Wraps whatever the Supabase client throws for [operation] into the
  /// matching [SupabaseChatCoreException] subtype, so callers only need to
  /// catch one type instead of every possible Supabase exception.
  SupabaseChatCoreException _mapError(
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
  /// [SupabaseChatCoreException] subtype (see [_mapError]).
  Future<T> _guard<T>(String operation, Future<T> Function() body) async {
    try {
      return await body();
    } catch (e, st) {
      throw _mapError(operation, e, st);
    }
  }

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<ChatRoom> createGroupRoom({
    ChatRoomRole creatorRole = ChatRoomRole.admin,
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<ChatUser> users,
  }) async {
    if (loggedSupabaseUser == null) {
      throw const SupabaseChatCoreAuthException(
        'createGroupRoom requires a logged-in user',
      );
    }

    final roomUsers = [loggedUser!.copyWith(role: creatorRole)] + users;

    return _guard('createGroupRoom', () async {
      final room = await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .insert({
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'imageUrl': imageUrl,
            'metadata': metadata,
            'name': name,
            'type': ChatRoomType.group.name,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'userIds': roomUsers.map((u) => u.id).toList(),
            'userRoles': roomUsers.fold<Map<String, String?>>(
              {},
              (previousValue, user) => {
                ...previousValue,
                user.id: user.role?.name,
              },
            ),
          })
          .select();

      return ChatRoom(
        id: room.first['id'].toString(),
        imageUrl: imageUrl,
        metadata: metadata,
        name: name,
        type: ChatRoomType.group,
        users: roomUsers,
      );
    });
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<ChatRoom> createRoom(
    ChatUser otherUser, {
    Map<String, dynamic>? metadata,
  }) async {
    final su = loggedSupabaseUser;

    if (su == null) {
      throw const SupabaseChatCoreAuthException(
        'createRoom requires a logged-in user',
      );
    }

    return _guard('createRoom', () async {
      // Sort two user ids array to always have the same array for both
      // users, this will make it easy to find the room if exist and make one
      // read only.
      final userIds = [su.id, otherUser.id]..sort();

      final roomQuery = await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .select()
          .eq('type', ChatRoomType.direct.name)
          .eq('userIds', userIds)
          .limit(1);
      // Check if room already exist.
      if (roomQuery.isNotEmpty) {
        final room = (await processRoomsRows(
          su,
          client,
          roomQuery,
          config.usersTableName,
          config.schema,
        )).first;

        return room;
      }

      final currentUser = await fetchUser(
        client,
        su.id,
        config.usersTableName,
        config.schema,
      );

      final users = [ChatUser.fromJson(currentUser), otherUser];

      // Create new room with sorted user ids array.
      final room = await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .insert({
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'imageUrl': null,
            'metadata': metadata,
            'name': null,
            'type': ChatRoomType.direct.name,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
            'userIds': userIds,
            'userRoles': null,
          })
          .select();
      return ChatRoom(
        id: room.first['id'].toString(),
        metadata: metadata,
        type: ChatRoomType.direct,
        users: users,
      );
    });
  }

  /// Update [ChatUser] in Supabase to store name and avatar used on
  /// rooms list.
  Future<void> updateUser(ChatUser user) => _guard('updateUser', () async {
    await client
        .schema(config.schema)
        .from(config.usersTableName)
        .update({
          'firstName': user.firstName,
          'imageUrl': user.imageUrl,
          'lastName': user.lastName,
          'metadata': user.metadata,
          'role': user.role?.name,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        })
        .eq('id', user.id);
  });

  /// Removes message.
  Future<bool> deleteMessage(String roomId, String messageId) =>
      _guard('deleteMessage', () async {
        final result = await client
            .schema(config.schema)
            .from(config.messagesTableName)
            .delete()
            .eq('roomId', roomId)
            .eq('id', messageId)
            .select();
        return result.isNotEmpty;
      });

  /// Removes room.
  Future<void> deleteRoom(String roomId) => _guard('deleteRoom', () async {
    await client
        .schema(config.schema)
        .from(config.roomsTableName)
        .delete()
        .eq('id', roomId);
  });

  /// Get room.
  Future<ChatRoom?> getRoom(String roomId) async {
    final fu = loggedSupabaseUser;
    if (fu == null) return null;
    return _guard('getRoom', () async {
      final doc = await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .select()
          .eq('id', roomId)
          .limit(1);
      return processRoomRow(
        doc.first,
        fu,
        client,
        config.usersTableName,
        config.schema,
      );
    });
  }

  /// Returns a stream of changes in a room from Supabase.
  Stream<ChatRoom> room(String roomId) {
    final fu = loggedSupabaseUser;
    if (fu == null) return const Stream.empty();
    return client
        .schema(config.schema)
        .from(config.roomsTableName)
        .stream(primaryKey: ['id'])
        .eq('id', roomId)
        .asyncMap((doc) async {
          try {
            return await processRoomRow(
              doc.first,
              fu,
              client,
              config.usersTableName,
              config.schema,
            );
          } catch (e, st) {
            throw _mapError('room', e, st);
          }
        });
  }

  /// Returns a paginated list of rooms from Supabase. Only rooms where current
  /// logged in user exist are returned.
  Future<List<ChatRoom>> rooms({
    String? filter,
    int? offset = 0,
    int? limit = 20,
  }) async {
    if (loggedSupabaseUser == null) return const [];
    return _guard('rooms', () async {
      final table = client.schema(config.schema).from(config.roomsViewName);

      final queryUnlimited = filter != null && filter != ''
          ? table.select().ilike('name', '%$filter%')
          : table.select();
      var query = queryUnlimited.order('updatedAt', ascending: false);
      if (offset != null && limit != null) {
        query = query.range(offset, offset + limit);
      } else if (limit != null) {
        query = query.limit(limit);
      }
      final response = await query;
      final rooms = <ChatRoom>[];
      for (var r in response) {
        rooms.add(
          await processRoomRow(
            r,
            loggedSupabaseUser!,
            client,
            config.usersTableName,
            config.schema,
          ),
        );
      }
      return rooms;
    });
  }

  static List<ChatRoom> updateRoomList(
    List<ChatRoom> roomsList,
    List<ChatRoom> newRooms,
  ) {
    final rooms = List<ChatRoom>.from(roomsList);
    for (var newRoom in newRooms) {
      final index = rooms.indexWhere((room) => room.id == newRoom.id);
      if (index != -1) {
        rooms[index] = newRoom;
      } else {
        rooms.add(newRoom);
      }
    }
    rooms.sort((a, b) => b.updatedAt?.compareTo(a.updatedAt ?? 0) ?? -1);
    return rooms;
  }

  /// Returns a stream of rooms updates from Supabase. Only rooms where current
  /// logged in user exist are returned.
  Stream<List<ChatRoom>> roomsUpdates() {
    final fu = loggedSupabaseUser;
    if (fu == null) return const Stream.empty();
    final controller = StreamController<List<ChatRoom>>();
    final roomsList = <ChatRoom>[];

    Future<void> onData(List<Map<String, dynamic>> data) async {
      try {
        for (var val in data) {
          final newRoom = await processRoomRow(
            val,
            fu,
            client,
            config.usersTableName,
            config.schema,
          );
          final index = roomsList.indexWhere((room) => room.id == newRoom.id);
          if (index != -1) {
            roomsList[index] = newRoom;
          } else {
            roomsList.add(newRoom);
          }
        }
        controller.sink.add(roomsList);
      } catch (e, st) {
        controller.sink.addError(_mapError('roomsUpdates', e, st));
      }
    }

    client
        .channel('${config.schema}:${config.roomsTableName}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: config.schema,
          table: config.roomsTableName,
          callback: (payload) => onData([payload.newRecord]),
        )
        .subscribe();
    return controller.stream;
  }

  /// Sends [message] to a room identified by [roomId]. Build [message] with
  /// one of `flutter_chat_core`'s `Message` factories (`Message.text`,
  /// `Message.image`, ...) and your own `id` (e.g. `const Uuid().v7()`) —
  /// `authorId` and `createdAt` are set by this method and don't need to be
  /// filled in [message]. Stores [message]'s `id` as-is, so a caller doing
  /// optimistic UI (see `SupabaseChatController.sendMessage`) gets the exact
  /// same row back from Realtime instead of a second, differently-id'd one.
  Future<void> sendMessage(core.Message message, String roomId) async {
    final su = loggedSupabaseUser;
    if (su == null) {
      throw const SupabaseChatCoreAuthException(
        'sendMessage requires a logged-in user',
      );
    }

    return _guard('sendMessage', () async {
      final messageMap = messageToRow(message);
      messageMap['id'] = message.id;
      messageMap['roomId'] = roomId;
      messageMap['authorId'] = su.id;
      messageMap['createdAt'] = DateTime.now().millisecondsSinceEpoch;
      messageMap['updatedAt'] = DateTime.now().millisecondsSinceEpoch;

      await client
          .schema(config.schema)
          .from(config.messagesTableName)
          .insert(messageMap);

      await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .update({'updatedAt': DateTime.now().millisecondsSinceEpoch})
          .eq('id', roomId);
    });
  }

  /// Updates a message in the Supabase. Accepts any message and a
  /// room ID. Message will probably be taken from the controller's
  /// `messages` list.
  Future<void> updateMessage(core.Message message, String roomId) =>
      _guard('updateMessage', () async {
        final messageMap = messageToRow(message);
        messageMap['updatedAt'] = DateTime.now().millisecondsSinceEpoch;

        await client
            .schema(config.schema)
            .from(config.messagesTableName)
            .update(messageMap)
            .eq('roomId', roomId)
            .eq('id', message.id);
      });

  /// Updates a room in the Supabase. Accepts any room.
  /// Room will probably be taken from the [rooms] stream.
  Future<void> updateRoom(ChatRoom room) async {
    if (loggedSupabaseUser == null) {
      throw const SupabaseChatCoreAuthException(
        'updateRoom requires a logged-in user',
      );
    }

    return _guard('updateRoom', () async {
      final isDirect = room.type == ChatRoomType.direct;

      final roomMap = <String, dynamic>{
        'imageUrl': isDirect ? null : room.imageUrl,
        'metadata': room.metadata,
        'name': isDirect ? null : room.name,
        'type': room.type.name,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'userIds': room.users.map((u) => u.id).toList(),
        'userRoles': room.users.fold<Map<String, String?>>(
          {},
          (previousValue, user) => {...previousValue, user.id: user.role?.name},
        ),
      };

      final lastMessages = room.lastMessages;
      if (lastMessages != null) {
        roomMap['lastMessages'] = lastMessages.map((m) {
          final messageMap = messageToRow(m);
          messageMap['id'] = m.id;
          messageMap['authorId'] = m.authorId;
          messageMap['createdAt'] = m.createdAt?.millisecondsSinceEpoch;
          return messageMap;
        }).toList();
      }

      await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .update(roomMap)
          .eq('id', room.id);
    });
  }

  /// Returns a paginated list of users from Supabase.
  Future<List<ChatUser>> users({
    String? filter,
    int? offset = 0,
    int? limit = 20,
  }) async {
    if (loggedSupabaseUser == null) return const [];
    return _guard('users', () async {
      final table = client.schema(config.schema).from(config.usersTableName);

      final queryUnlimited = filter != null && filter != ''
          ? table.select().or(
              'or(firstName.ilike.%$filter%,lastName.ilike.%$filter%)',
            )
          : table.select();
      var query = queryUnlimited
          .order('firstName', ascending: true)
          .order('lastName', ascending: true);
      if (offset != null && limit != null) {
        query = query.range(offset, offset + limit);
      } else if (limit != null) {
        query = query.limit(limit);
      }
      final response = await query;
      return response.map((e) => ChatUser.fromJson(e)).toList();
    });
  }

  /// Returns a user from Supabase.
  Future<ChatUser?> user({required String uid}) => _guard('user', () async {
    final response = await client
        .schema(config.schema)
        .from(config.usersTableName)
        .select()
        .eq('id', uid)
        .limit(1);
    return response.isNotEmpty ? ChatUser.fromJson(response.first) : null;
  });
}
