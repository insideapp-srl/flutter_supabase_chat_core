import 'dart:async';

import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../util.dart';
import 'supabase_chat_core_config.dart';
import 'user_online_status.dart';

/// Provides access to Supabase chat data. Singleton, use
/// SupabaseChatCore.instance to access methods.
class SupabaseChatCore {
  SupabaseChatCore._privateConstructor() {
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      supabaseUser = data.session?.user;
      _currentUserOnlineStatusChannel = supabaseUser != null
          ? getUserOnlineStatusChannel(supabaseUser!.id)
          : null;
    });
  }

  /// Config to set custom names for users, room and messages tables. Also
  /// see [SupabaseChatCoreConfig].
  SupabaseChatCoreConfig config = const SupabaseChatCoreConfig(
    'chats',
    'rooms',
    'messages',
    'users',
    'online-user-',
  );

  /// Current logged in user in Supabase. Does not update automatically.
  /// Use [Supabase.instance.client.auth.onAuthStateChange] to listen to the state changes.
  User? supabaseUser = Supabase.instance.client.auth.currentUser;

  /// Returns user online status realtime channel .
  RealtimeChannel getUserOnlineStatusChannel(String uid) =>
      client.channel('${config.realtimeOnlineUserPrefixChannel}$uid');

  /// Returns a current user online status realtime channel .
  RealtimeChannel? _currentUserOnlineStatusChannel;

  bool _userStatusSubscribed = false;
  bool _userStatusSubscribing = false;

  Future<void> _trackUserStatus() async {
    final userStatus = {
      'uid': supabaseUser?.id,
      'online_at': DateTime.now().toIso8601String(),
    };
    await _currentUserOnlineStatusChannel?.track(userStatus);
  }

  Future<void> setPresenceStatus(UserOnlineStatus status) async {
    if (!_userStatusSubscribed && !_userStatusSubscribing) {
      _userStatusSubscribing = true;
      _currentUserOnlineStatusChannel?.subscribe(
        (status, error) async {
          if (status != RealtimeSubscribeStatus.subscribed) return;
          _userStatusSubscribed = true;
          _userStatusSubscribing = false;
          await _trackUserStatus();
        },
      );
    }

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

  /// Singleton instance.
  static final SupabaseChatCore instance =
      SupabaseChatCore._privateConstructor();

  /// Gets proper [SupabaseClient] instance.
  SupabaseClient get client => Supabase.instance.client;

  /// Sets custom config to change default names for users, rooms
  /// and messages tables. Also see [SupabaseChatCoreConfig].
  void setConfig(SupabaseChatCoreConfig supabaseChatCoreConfig) {
    config = supabaseChatCoreConfig;
  }

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
    if (supabaseUser == null) return Future.error('User does not exist');

    final currentUser = await fetchUser(
      client,
      supabaseUser!.id,
      config.usersTableName,
      config.schema,
      role: creatorRole.toShortString(),
    );

    final roomUsers = [types.User.fromJson(currentUser)] + users;

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
    final su = supabaseUser;

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
  Future<void> deleteMessage(String roomId, String messageId) async {
    await client
        .schema(config.schema)
        .from(config.messagesTableName)
        .delete()
        .eq('roomId', roomId)
        .eq('id', messageId);
  }

  /// Removes room.
  Future<void> deleteRoom(String roomId) async {
    await client
        .schema(config.schema)
        .from(config.roomsTableName)
        .delete()
        .eq('id', roomId);
  }

  /// Returns a stream of messages from Supabase for a given room.
  Stream<List<types.Message>> messages(types.Room room) {
    final query = client
        .schema(config.schema)
        .from(config.messagesTableName)
        .stream(primaryKey: ['id'])
        .eq('roomId', int.parse(room.id))
        .order('createdAt', ascending: false);
    return query.map(
      (snapshot) => snapshot.fold<List<types.Message>>(
        [],
        (previousMessages, data) {
          final author = room.users.firstWhere(
            (u) => u.id == data['authorId'],
            orElse: () => types.User(id: data['authorId'] as String),
          );
          data['author'] = author.toJson();
          data['id'] = data['id'].toString();
          data['roomId'] = data['roomId'].toString();
          final newMessage = types.Message.fromJson(data);
          final index =
              previousMessages.indexWhere((msg) => msg.id == newMessage.id);
          if (index != -1) {
            previousMessages[index] = newMessage;
          } else {
            previousMessages.add(newMessage);
          }
          return previousMessages;
        },
      ),
    );
  }

  /// Returns a stream of changes in a room from Supabase.
  Stream<types.Room> room(String roomId) {
    final fu = supabaseUser;
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

  /// Returns a stream of online user state from Supabase Realtime.
  Stream<UserOnlineStatus> userOnlineStatus(String uid) {
    final controller = StreamController<UserOnlineStatus>();
    UserOnlineStatus userStatus(List<Presence> presences, String uid) =>
        presences.map((e) => e.payload['uid']).contains(uid)
            ? UserOnlineStatus.online
            : UserOnlineStatus.offline;
    getUserOnlineStatusChannel(uid).onPresenceJoin((payload) {
      controller.sink.add(userStatus(payload.newPresences, uid));
    }).onPresenceLeave((payload) {
      controller.sink.add(userStatus(payload.currentPresences, uid));
    }).subscribe();
    return controller.stream;
  }

  /// Returns a stream of rooms from Supabase. Only rooms where current
  /// logged in user exist are returned. [orderByUpdatedAt] is used in case
  /// you want to have last modified rooms on top, there are a couple
  /// of things you will need to do though:
  /// 1) Make sure `updatedAt` exists on all rooms
  /// 2) Write a Cloud Function which will update `updatedAt` of the room
  /// when the room changes or new messages come in
  /// 3) Create an Index (Firestore Database -> Indexes tab) where collection ID
  /// is `rooms`, field indexed are `userIds` (type Arrays) and `updatedAt`
  /// (type Descending), query scope is `Collection`.
  Stream<List<types.Room>> rooms({bool orderByUpdatedAt = true}) {
    final fu = supabaseUser;
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
      if (orderByUpdatedAt) {
        roomsList.sort(
          (a, b) => a.createdAt?.compareTo(b.createdAt ?? 0) ?? -1,
        );
      }
      controller.sink.add(roomsList);
    }

    final collection = orderByUpdatedAt
        ? client
            .schema(config.schema)
            .from(config.roomsTableName)
            .select()
            .order('updatedAt', ascending: false)
        : client.schema(config.schema).from(config.roomsTableName).select();

    collection.then(onData);
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
  void sendMessage(dynamic partialMessage, String roomId) async {
    if (supabaseUser == null) return;

    types.Message? message;

    if (partialMessage is types.PartialCustom) {
      message = types.CustomMessage.fromPartial(
        author: types.User(id: supabaseUser!.id),
        id: '',
        partialCustom: partialMessage,
      );
    } else if (partialMessage is types.PartialFile) {
      message = types.FileMessage.fromPartial(
        author: types.User(id: supabaseUser!.id),
        id: '',
        partialFile: partialMessage,
      );
    } else if (partialMessage is types.PartialImage) {
      message = types.ImageMessage.fromPartial(
        author: types.User(id: supabaseUser!.id),
        id: '',
        partialImage: partialMessage,
      );
    } else if (partialMessage is types.PartialText) {
      message = types.TextMessage.fromPartial(
        author: types.User(id: supabaseUser!.id),
        id: '',
        partialText: partialMessage,
      );
    }

    if (message != null) {
      final messageMap = message.toJson();
      messageMap.removeWhere((key, value) => key == 'author' || key == 'id');
      messageMap['roomId'] = roomId;
      messageMap['authorId'] = supabaseUser!.id;
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
  void updateRoom(types.Room room) async {
    if (supabaseUser == null) return;

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

  /// Returns a stream of all users from Supabase.
  Stream<List<types.User>> users() {
    if (supabaseUser == null) return const Stream.empty();
    return client
        .schema(config.schema)
        .from(config.usersTableName)
        .stream(primaryKey: ['id']).map(
      (snapshot) => snapshot.fold<List<types.User>>(
        [],
        (previousValue, data) {
          if (supabaseUser!.id == data['id']) return previousValue;
          return [...previousValue, types.User.fromJson(data)];
        },
      ),
    );
  }
}
