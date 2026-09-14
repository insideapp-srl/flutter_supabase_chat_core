import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'class/chat_room.dart';
import 'class/chat_room_type.dart';
import 'class/chat_user.dart';

/// Fetches a user row from the `users` table.
Future<Map<String, dynamic>> fetchUser(
  SupabaseClient instance,
  String userId,
  String usersTableName,
  String schema, {
  String? role,
}) async {
  final data =
      (await instance
              .schema(schema)
              .from(usersTableName)
              .select()
              .eq('id', userId)
              .limit(1))
          .first;
  data['role'] = role;
  return data;
}

/// Returns a list of [ChatRoom] built from Supabase rows.
/// If a room has 2 participants, sets correct room name and image.
Future<List<ChatRoom>> processRoomsRows(
  User supabaseUser,
  SupabaseClient instance,
  List<dynamic> rows,
  String usersTableName,
  String schema,
) async => await Future.wait(
  rows.map(
    (doc) =>
        processRoomRow(doc, supabaseUser, instance, usersTableName, schema),
  ),
);

/// Returns a [ChatRoom] built from a Supabase row.
Future<ChatRoom> processRoomRow(
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
  final rawUsers =
      data['users']?.map((e) {
        e['role'] = userRoles?[e['id']];
        return e;
      }).toList() ??
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

  final roomType = ChatRoomType.values.byName(type);

  if (roomType == ChatRoomType.direct) {
    final index = rawUsers.indexWhere((u) => u['id'] != supabaseUser.id);
    if (index >= 0) {
      final otherUser = rawUsers[index];
      imageUrl = otherUser['imageUrl'] as String?;
      name = '${otherUser['firstName'] ?? ''} ${otherUser['lastName'] ?? ''}'
          .trim();
    }
  }

  final users = rawUsers
      .map<ChatUser>((u) => ChatUser.fromJson(u as Map<String, dynamic>))
      .toList();

  final rawLastMessages = data['lastMessages'] as List<dynamic>?;
  final lastMessages = rawLastMessages
      ?.map((m) => messageFromRow(m as Map<String, dynamic>))
      .toList();

  return ChatRoom(
    id: data['id'].toString(),
    imageUrl: imageUrl,
    metadata: data['metadata'] as Map<String, dynamic>?,
    name: name,
    type: roomType,
    users: users,
    lastMessages: lastMessages,
    createdAt: data['createdAt'] as int?,
    updatedAt: data['updatedAt'] as int?,
  );
}

/// Builds a `flutter_chat_core` [core.Message] out of a raw `messages` (or
/// `messages_l`) table row.
///
/// The `messages` table columns match `flutter_chat_core`'s v2 field names
/// directly (`source`, `waveform`, `linkPreviewData`, `replyToMessageId`,
/// ...), so this only needs to: stringify the bigint/uuid `id`/`authorId`,
/// convert `duration` from the DB's milliseconds to v2's seconds, and
/// normalize a legacy-shaped `linkPreviewData` (e.g. missing the image
/// width/height v2 requires).
core.Message messageFromRow(Map<String, dynamic> row) {
  final id = row['id'].toString();
  final authorId = row['authorId'].toString();

  final json = <String, dynamic>{...row}
    ..['id'] = id
    ..['authorId'] = authorId
    ..['type'] = row['type'] ?? 'unsupported'
    ..remove('roomId');

  final durationMs = row['duration'] as int?;
  if (durationMs != null) {
    json['duration'] = (durationMs / 1000).round();
  }

  final preview = row['linkPreviewData'] as Map<String, dynamic>?;
  if (preview == null || preview['link'] == null) {
    json.remove('linkPreviewData');
  } else {
    final image = preview['image'] as Map<String, dynamic>?;
    json['linkPreviewData'] = {
      'link': preview['link'],
      'title': preview['title'],
      'description': preview['description'],
      if (image != null && image['url'] != null)
        'image': {
          'url': image['url'],
          'width': (image['width'] as num?)?.toDouble() ?? 0,
          'height': (image['height'] as num?)?.toDouble() ?? 0,
        },
    };
  }

  try {
    return core.Message.fromJson(json);
  } on TypeError {
    // Row didn't carry the fields required by its declared type (e.g. a
    // legacy row with unexpected nulls). Fall back to an unsupported
    // message instead of crashing the realtime/pagination stream.
    return core.Message.unsupported(
      id: id,
      authorId: authorId,
      createdAt: row['createdAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              row['createdAt'] as int,
              isUtc: true,
            )
          : null,
      metadata: row['metadata'] as Map<String, dynamic>?,
    );
  }
}

/// Columns of the `messages` table that a [core.Message] can populate.
/// `id`, `authorId`, `roomId` and `createdAt` are deliberately excluded:
/// callers set those explicitly (see [SupabaseChatCore.sendMessage]).
const _messageRowKeys = {
  'type',
  'status',
  'metadata',
  'reactions',
  'pinned',
  'replyToMessageId',
  'text',
  'source',
  'name',
  'mimeType',
  'size',
  'width',
  'height',
  'duration',
  'waveform',
  'linkPreviewData',
};

/// Builds a `messages` table row out of a `flutter_chat_core` [core.Message].
Map<String, dynamic> messageToRow(core.Message message) {
  if (message is core.TextStreamMessage) {
    throw ArgumentError(
      'TextStreamMessage is a client-side only placeholder and cannot be '
      'persisted. Send a TextMessage once streaming is complete.',
    );
  }
  if (message is core.UnsupportedMessage) {
    throw ArgumentError('Cannot persist an UnsupportedMessage.');
  }

  final json = message.toJson();
  final row = <String, dynamic>{
    for (final key in _messageRowKeys)
      if (json.containsKey(key)) key: json[key],
  };

  final duration = row['duration'];
  if (duration is int) {
    row['duration'] = duration * 1000; // stored in milliseconds
  }

  return row;
}
