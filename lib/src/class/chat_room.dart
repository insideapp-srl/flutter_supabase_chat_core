import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:meta/meta.dart';

import 'chat_room_type.dart';
import 'chat_user.dart';

/// Represents a room/conversation stored in the `rooms` table.
///
/// `flutter_chat_core` v2 dropped the concept of a "room" entirely — it only
/// deals with messages and users. This class fills that gap and stays
/// specific to this package.
@immutable
class ChatRoom {
  const ChatRoom({
    required this.id,
    this.imageUrl,
    this.metadata,
    this.name,
    required this.type,
    required this.users,
    this.lastMessages,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String? imageUrl;
  final Map<String, dynamic>? metadata;
  final String? name;
  final ChatRoomType type;
  final List<ChatUser> users;

  /// Preview of the most recent message(s), already converted to
  /// `flutter_chat_core`'s [core.Message].
  final List<core.Message>? lastMessages;

  /// Epoch milliseconds.
  final int? createdAt;

  /// Epoch milliseconds.
  final int? updatedAt;

  ChatRoom copyWith({
    String? imageUrl,
    Map<String, dynamic>? metadata,
    String? name,
    List<ChatUser>? users,
    List<core.Message>? lastMessages,
    int? updatedAt,
  }) => ChatRoom(
    id: id,
    imageUrl: imageUrl ?? this.imageUrl,
    metadata: metadata ?? this.metadata,
    name: name ?? this.name,
    type: type,
    users: users ?? this.users,
    lastMessages: lastMessages ?? this.lastMessages,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  bool operator ==(Object other) => other is ChatRoom && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
