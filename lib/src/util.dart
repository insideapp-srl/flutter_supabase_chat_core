import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Extension with one [toShortString] method.
extension RoleToShortString on types.Role {
  /// Converts enum to the string equal to enum's name.
  String toShortString() => toString().split('.').last;
}

/// Extension with one [toShortString] method.
extension RoomTypeToShortString on types.RoomType {
  /// Converts enum to the string equal to enum's name.
  String toShortString() => toString().split('.').last;
}

/// Fetches user from Firebase and returns a promise.
Future<Map<String, dynamic>> fetchUser(
  SupabaseClient instance,
  String userId,
  String usersTableName,
  String schema, {
  String? role,
}) async {
  final data = (await instance
          .schema(schema)
          .from(usersTableName)
          .select()
          .eq('id', userId)
          .limit(1))
      .first;
  data['role'] = role;
  return data;
}

/// Returns a list of [types.Room] created from Firebase query.
/// If room has 2 participants, sets correct room name and image.
Future<List<types.Room>> processRoomsRows(
  User supabaseUser,
  SupabaseClient instance,
  List<dynamic> rows,
  String usersTableName,
  String schema,
) async =>
    await Future.wait(
      rows.map(
        (doc) => processRoomRow(
          doc,
          supabaseUser,
          instance,
          usersTableName,
          schema,
        ),
      ),
    );

/// Returns a [types.Room] created from Firebase document.
Future<types.Room> processRoomRow(
  Map<String, dynamic> data,
  User supabaseUser,
  SupabaseClient instance,
  String usersTableName,
  String schema,
) async {
  var imageUrl = data['imageUrl'] as String?;
  var name = data['name'] as String?;
  final type = data['type'] as String;
  final userIds = data['userIds'] as List<dynamic>;
  final userRoles = data['userRoles'] as Map<String, dynamic>?;
  final users = data['users']?.map(
        (e) {
          e['role'] = userRoles?[e['id']];
          return e;
        },
      ).toList() ??
      await Future.wait(
        userIds.map(
          (userId) => fetchUser(
            instance,
            userId as String,
            usersTableName,
            schema,
            role: userRoles?[userId] as String?,
          ),
        ),
      );
  if (type == types.RoomType.direct.toShortString()) {
    final index = users.indexWhere(
      (u) => u['id'] != supabaseUser.id,
    );
    if (index >= 0) {
      final otherUser = users[index];
      imageUrl = otherUser['imageUrl'] as String?;
      name = '${otherUser['firstName'] ?? ''} ${otherUser['lastName'] ?? ''}'
          .trim();
    }
  }
  data['imageUrl'] = imageUrl;
  data['name'] = name;
  data['users'] = users;
  data['id'] = data['id'].toString();
  if (data['lastMessages'] != null) {
    final lastMessages = data['lastMessages'].map((lm) {
      final author = users.firstWhere(
        (u) => u['id'] == lm['authorId'],
        orElse: () => {'id': lm['authorId'] as String},
      );
      lm['author'] = author;
      lm['id'] = lm['id'].toString();
      lm['roomId'] = lm['roomId'].toString();
      return lm;
    }).toList();
    data['lastMessages'] = lastMessages;
  }
  return types.Room.fromJson(data);
}
