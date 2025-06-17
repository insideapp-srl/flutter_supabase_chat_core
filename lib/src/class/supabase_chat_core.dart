import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
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
        _loggedUser = await user(uid: loggedSupabaseUser!.id);
        if (_currentUserOnlineStatusChannel == null) {
          _currentUserOnlineStatusChannel ??=
              _getUserOnlineStatusChannel(loggedSupabaseUser!.id);
          _currentUserOnlineStatusChannel?.subscribe(
            (status, error) async {
              _userStatusSubscribed =
                  status == RealtimeSubscribeStatus.subscribed;
              if (_lastOnlineStatus == UserOnlineStatus.online) {
                await _trackUserStatus();
              } else {
                await _currentUserOnlineStatusChannel?.untrack();
              }
            },
          );
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
    'online-user-',
    //online-user-${uid}
    'chat-user-typing-',
    //chat-user-typing-${room_id}
    'chats_assets',
  );

  /// Sets custom config to change default names for users, rooms
  /// and messages tables. Also see [SupabaseChatCoreConfig].
  void setConfig(SupabaseChatCoreConfig supabaseChatCoreConfig) {
    config = supabaseChatCoreConfig;
  }

  /// Current logged in user in Supabase. Is update automatically.
  User? get loggedSupabaseUser => Supabase.instance.client.auth.currentUser;

  types.User? _loggedUser;

  /// Current logged in user. Is update automatically.
  types.User? get loggedUser => _loggedUser;

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
      _onlineUserChannels[uid]!.onPresenceJoin((payload) {
        controller.sink.add(_userStatus(payload.newPresences, uid));
      }).onPresenceLeave((payload) {
        controller.sink.add(_userStatus(payload.currentPresences, uid));
      }).subscribe();
    }
    return controller.stream;
  }

  /// Returns the URL of an asset path in the bucket
  String getAssetUrl(String path) =>
      '${client.storage.url}/object/authenticated/${config.chatAssetsBucket}/$path';

  /// Returns a path based on the specified room id and asset name
  String generateRoomAssetPath(types.Room room, String assetName) =>
      '${room.id}/${const Uuid().v1()}-$assetName';

  /// Allows you to upload an asset to a specific room by returning its URL and mimeType
  Future<UploadAssetResult> uploadAsset(
    types.Room room,
    String assetName,
    Uint8List bytes,
  ) async {
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
  }

  /// Gets proper [SupabaseClient] instance.
  SupabaseClient get client => Supabase.instance.client;

  /// Return header for authenticate api calls to Supabase
  Map<String, String> get httpSupabaseHeaders => {
        'Authorization': 'Bearer ${client.auth.currentSession?.accessToken}',
      };

  /// Creates a chat group room with [users]. Creator is automatically
  /// added to the group. [name] is required and will be used as
  /// a group name. Add an optional [imageUrl] that will be a group avatar
  /// and [metadata] for any additional custom data.
  Future<types.Room> createGroupRoom({
    types.Role creatorRole = types.Role.admin,
    String? imageUrl,
    Map<String, dynamic>? metadata,
    required String name,
    required List<types.User> users,
  }) async {
    if (loggedSupabaseUser == null) return Future.error('User does not exist');

    final roomUsers = [loggedUser!.copyWith(role: creatorRole)] + users;

    final room =
        await client.schema(config.schema).from(config.roomsTableName).insert({
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'imageUrl': imageUrl,
      'metadata': metadata,
      'name': name,
      'type': types.RoomType.group.toShortString(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'userIds': roomUsers.map((u) => u.id).toList(),
      'userRoles': roomUsers.fold<Map<String, String?>>(
        {},
        (previousValue, user) => {
          ...previousValue,
          user.id: user.role?.toShortString(),
        },
      ),
    }).select();

    return types.Room(
      id: room.first['id'].toString(),
      imageUrl: imageUrl,
      metadata: metadata,
      name: name,
      type: types.RoomType.group,
      users: roomUsers,
    );
  }

  /// Creates a direct chat for 2 people. Add [metadata] for any additional
  /// custom data.
  Future<types.Room> createRoom(
    types.User otherUser, {
    Map<String, dynamic>? metadata,
  }) async {
    final su = loggedSupabaseUser;

    if (su == null) return Future.error('User does not exist');

    // Sort two user ids array to always have the same array for both users,
    // this will make it easy to find the room if exist and make one read only.
    final userIds = [su.id, otherUser.id]..sort();

    final roomQuery = await client
        .schema(config.schema)
        .from(config.roomsTableName)
        .select()
        .eq('type', types.RoomType.direct.toShortString())
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
      ))
          .first;

      return room;
    }

    final currentUser = await fetchUser(
      client,
      su.id,
      config.usersTableName,
      config.schema,
    );

    final users = [types.User.fromJson(currentUser), otherUser];

    // Create new room with sorted user ids array.
    final room =
        await client.schema(config.schema).from(config.roomsTableName).insert({
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'imageUrl': null,
      'metadata': metadata,
      'name': null,
      'type': types.RoomType.direct.toShortString(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'userIds': userIds,
      'userRoles': null,
    }).select();
    return types.Room(
      id: room.first['id'].toString(),
      metadata: metadata,
      type: types.RoomType.direct,
      users: users,
    );
  }

  /// Update [types.User] in Supabase to store name and avatar used on
  /// rooms list.
  Future<void> updateUser(types.User user) async {
    await client.schema(config.schema).from(config.usersTableName).update({
      'firstName': user.firstName,
      'imageUrl': user.imageUrl,
      'lastName': user.lastName,
      'metadata': user.metadata,
      'role': user.role?.toShortString(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    }).eq('id', user.id);
  }

  /// Removes message.
  Future<bool> deleteMessage(String roomId, String messageId) async {
    final result = await client
        .schema(config.schema)
        .from(config.messagesTableName)
        .delete()
        .eq('roomId', roomId)
        .eq('id', messageId)
        .select();
    return result.isNotEmpty;
  }

  /// Removes room.
  Future<void> deleteRoom(String roomId) async {
    await client
        .schema(config.schema)
        .from(config.roomsTableName)
        .delete()
        .eq('id', roomId);
  }

  /// Get room.
  Future<types.Room?> getRoom(String roomId) async {
    final fu = loggedSupabaseUser;
    if (fu == null) return null;
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
  }

  /// Returns a stream of changes in a room from Supabase.
  Stream<types.Room> room(String roomId) {
    final fu = loggedSupabaseUser;
    if (fu == null) return const Stream.empty();
    return client
        .schema(config.schema)
        .from(config.roomsTableName)
        .stream(primaryKey: ['id'])
        .eq('id', roomId)
        .asyncMap(
          (doc) => processRoomRow(
            doc.first,
            fu,
            client,
            config.usersTableName,
            config.schema,
          ),
        );
  }

  /// Returns a paginated list of rooms from Supabase. Only rooms where current
  /// logged in user exist are returned.
  Future<List<types.Room>> rooms({
    String? filter,
    int? offset = 0,
    int? limit = 20,
  }) async {
    if (loggedSupabaseUser == null) return const [];
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
    final rooms = <types.Room>[];
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
  }

  static List<types.Room> updateRoomList(
    List<types.Room> roomsList,
    List<types.Room> newRooms,
  ) {
    final rooms = List<types.Room>.from(roomsList);
    for (var newRoom in newRooms) {
      final index = rooms.indexWhere((room) => room.id == newRoom.id);
      if (index != -1) {
        rooms[index] = newRoom;
      } else {
        rooms.add(newRoom);
      }
    }
    rooms.sort(
      (a, b) => b.updatedAt?.compareTo(a.updatedAt ?? 0) ?? -1,
    );
    return rooms;
  }

  /// Returns a stream of rooms updates from Supabase. Only rooms where current
  /// logged in user exist are returned.
  Stream<List<types.Room>> roomsUpdates() {
    final fu = loggedSupabaseUser;
    if (fu == null) return const Stream.empty();
    final controller = StreamController<List<types.Room>>();
    final roomsList = <types.Room>[];

    Future<void> onData(List<Map<String, dynamic>> data) async {
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

  /// Sends a message to the Supabase. Accepts any partial message and a
  /// room ID. If arbitrary data is provided in the [partialMessage]
  /// does nothing.
  Future<void> sendMessage(dynamic partialMessage, String roomId) async {
    if (loggedSupabaseUser == null) return;

    types.Message? message;

    if (partialMessage is types.PartialCustom) {
      message = types.CustomMessage.fromPartial(
        author: types.User(id: loggedSupabaseUser!.id),
        id: '',
        partialCustom: partialMessage,
      );
    } else if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        author: types.User(id: loggedSupabaseUser!.id),
        id: '',
        partialFile: partialMessage,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        author: types.User(id: loggedSupabaseUser!.id),
        id: '',
        partialImage: partialMessage,
      );
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
        author: types.User(id: loggedSupabaseUser!.id),
        id: '',
        partialText: partialMessage,
      );
    }

    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['roomId'] = roomId;
      messageMap['authorId'] = loggedSupabaseUser!.id;
      messageMap['createdAt'] = DateTime.now().millisecondsSinceEpoch;
      messageMap['updatedAt'] = DateTime.now().millisecondsSinceEpoch;

      await client
          .schema(config.schema)
          .from(config.messagesTableName)
          .insert(messageMap);

      await client
          .schema(config.schema)
          .from(config.roomsTableName)
          .update({'updatedAt': DateTime.now().millisecondsSinceEpoch}).eq(
        'id',
        roomId,
      );
    }
  }

  /// Updates a message in the Supabase. Accepts any message and a
  /// room ID. Message will probably be taken from the [messages] stream.
  Future<void> updateMessage(types.Message message, String roomId) async {
    //if (supabaseUser == null) return;
    //if (message.author.id != supabaseUser!.id) return;

    final messageMap = message.toJson();
    messageMap.removeWhere(
      (key, value) => key == 'author' || key == 'createdAt' || key == 'id',
    );
    //messageMap['authorId'] = message.author.id;
    messageMap['updatedAt'] = DateTime.now().millisecondsSinceEpoch;

    await client
        .schema(config.schema)
        .from(config.messagesTableName)
        .update(messageMap)
        .eq('roomId', roomId)
        .eq('id', message.id);
  }

  /// Updates a room in the Supabase. Accepts any room.
  /// Room will probably be taken from the [rooms] stream.
  Future<void> updateRoom(types.Room room) async {
    if (loggedSupabaseUser == null) return;

    final roomMap = room.toJson();
    roomMap.removeWhere(
      (key, value) =>
          key == 'createdAt' ||
          key == 'id' ||
          key == 'lastMessages' ||
          key == 'users',
    );

    if (room.type == types.RoomType.direct) {
      roomMap['imageUrl'] = null;
      roomMap['name'] = null;
    }

    roomMap['lastMessages'] = room.lastMessages?.map((m) {
      final messageMap = m.toJson();

      messageMap.removeWhere(
        (key, value) =>
            key == 'author' ||
            key == 'createdAt' ||
            key == 'id' ||
            key == 'updatedAt',
      );

      messageMap['authorId'] = m.author.id;

      return messageMap;
    }).toList();
    roomMap['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
    roomMap['userIds'] = room.users.map((u) => u.id).toList();

    await client
        .schema(config.schema)
        .from(config.roomsTableName)
        .update(roomMap)
        .eq('id', room.id);
  }

  /// Returns a paginated list of users from Supabase.
  Future<List<types.User>> users({
    String? filter,
    int? offset = 0,
    int? limit = 20,
  }) async {
    if (loggedSupabaseUser == null) return const [];
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
    return response
        .map(
          (e) => types.User.fromJson(e),
        )
        .toList();
  }

  /// Returns a user from Supabase.
  Future<types.User?> user({
    required String uid,
  }) async {
    final response = await client
        .schema(config.schema)
        .from(config.usersTableName)
        .select()
        .eq('id', uid)
        .limit(1);
    return response.isNotEmpty ? types.User.fromJson(response.first) : null;
  }
}
