import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:meta/meta.dart';

import '../util.dart';
import 'chat_room_role.dart';
import 'chat_room_type.dart';
import 'chat_user.dart';

/// Represents a room/conversation stored in the `rooms` table.
///
/// `flutter_chat_core` v2 dropped the concept of a "room" entirely — it only
/// deals with messages and users. This class fills that gap and stays
/// specific to this package.
@immutable
class ChatRoom {
  /// Creates a room.
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
    this.unreadCount = 0,
    this.lastReadAt,
    this.pinnedAt,
    this.mutedUntil,
  });

  /// Builds a room out of a `rooms_l` view row.
  ///
  /// For a [ChatRoomType.direct] room, [name] and [imageUrl] are taken from
  /// the member other than [currentUserId] (the view already computes the
  /// name, this also fills in the avatar).
  factory ChatRoom.fromJson(
    Map<String, dynamic> json, {
    String? currentUserId,
  }) {
    final type =
        ChatRoomType.values.asNameMap()[json['type'] as String?] ??
        ChatRoomType.group;
    final users = ((json['users'] as List?) ?? const [])
        .map((u) => ChatUser.fromJson((u as Map).cast<String, dynamic>()))
        .toList();

    var name = json['name'] as String?;
    var imageUrl = json['imageUrl'] as String?;
    if (type == ChatRoomType.direct && currentUserId != null) {
      for (final user in users) {
        if (user.id != currentUserId) {
          imageUrl = user.imageUrl;
          final fullName = user.fullName;
          if (fullName.isNotEmpty) name = fullName;
          break;
        }
      }
    }

    final rawLastMessages = json['lastMessages'] as List?;
    return ChatRoom(
      id: json['id'].toString(),
      imageUrl: imageUrl,
      metadata: (json['metadata'] as Map?)?.cast<String, dynamic>(),
      name: name?.trim().isEmpty ?? true ? null : name!.trim(),
      type: type,
      users: users,
      lastMessages: rawLastMessages
          ?.whereType<Map>()
          .map((m) => messageFromRow(m.cast<String, dynamic>()))
          .toList(),
      createdAt: parseChatDate(json['createdAt']),
      updatedAt: parseChatDate(json['updatedAt']),
      unreadCount: (json['unreadCount'] as num?)?.toInt() ?? 0,
      lastReadAt: parseChatDate(json['lastReadAt']),
      pinnedAt: parseChatDate(json['pinnedAt']),
      mutedUntil: _parseMutedUntil(json['mutedUntil']),
    );
  }

  // Postgres serializes the timestamptz 'infinity' (muted for ever) as the
  // literal string "infinity", which DateTime can't represent.
  static DateTime? _parseMutedUntil(Object? value) =>
      value == 'infinity' ? mutedForever : parseChatDate(value);

  /// [mutedUntil] value meaning "muted until unmuted".
  static final DateTime mutedForever = DateTime.utc(9999, 12, 31);

  /// Unique identifier (uuid).
  final String id;

  /// Room avatar URL. For a direct room, the other member's avatar.
  final String? imageUrl;

  /// Additional custom data.
  final Map<String, dynamic>? metadata;

  /// Room name. For a direct room, the other member's full name.
  final String? name;

  /// Direct (1-to-1) or group room.
  final ChatRoomType type;

  /// Room members, each carrying its room-specific [ChatUser.role].
  final List<ChatUser> users;

  /// Preview of the most recent message(s), already converted to
  /// `flutter_chat_core`'s [core.Message].
  final List<core.Message>? lastMessages;

  /// When the room was created.
  final DateTime? createdAt;

  /// When the room was last updated (bumped by every new message).
  final DateTime? updatedAt;

  /// Messages from other members newer than [lastReadAt] (for the current
  /// user). Always `0` for rooms not loaded from the `rooms_l` view.
  final int unreadCount;

  /// When the current user last marked this room as read.
  final DateTime? lastReadAt;

  /// When the current user pinned this room on top of their list (`null`
  /// when not pinned). Per user.
  final DateTime? pinnedAt;

  /// Until when the current user muted this room (`null` when not muted,
  /// [mutedForever] for ever). Per user.
  final DateTime? mutedUntil;

  /// Whether the current user pinned this room.
  bool get isPinned => pinnedAt != null;

  /// Whether the room is currently muted for the current user.
  bool get isMuted =>
      mutedUntil != null && mutedUntil!.isAfter(DateTime.now().toUtc());

  /// The most recent message, if any.
  core.Message? get lastMessage => lastMessages == null || lastMessages!.isEmpty
      ? null
      : lastMessages!.first;

  /// The member with id [userId], if any.
  ChatUser? member(String userId) {
    for (final user in users) {
      if (user.id == userId) return user;
    }
    return null;
  }

  /// Role of the member with id [userId] (`null` for a plain member or a
  /// non-member).
  ChatRoomRole? roleOf(String userId) => member(userId)?.role;

  /// For a direct room, the member that isn't [currentUserId].
  ChatUser? otherUser(String currentUserId) {
    if (type != ChatRoomType.direct) return null;
    for (final user in users) {
      if (user.id != currentUserId) return user;
    }
    return null;
  }

  /// Returns a copy with the given fields replaced. [pinnedAt] and
  /// [mutedUntil] take a function so they can be reset to `null`.
  ChatRoom copyWith({
    String? imageUrl,
    Map<String, dynamic>? metadata,
    String? name,
    List<ChatUser>? users,
    List<core.Message>? lastMessages,
    DateTime? updatedAt,
    int? unreadCount,
    DateTime? lastReadAt,
    DateTime? Function()? pinnedAt,
    DateTime? Function()? mutedUntil,
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
    unreadCount: unreadCount ?? this.unreadCount,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    pinnedAt: pinnedAt != null ? pinnedAt() : this.pinnedAt,
    mutedUntil: mutedUntil != null ? mutedUntil() : this.mutedUntil,
  );

  /// Value equality over every field: a room refetched after a change (a new
  /// message, the unread count, a rename) is not `==` to the copy a list or a
  /// `ValueNotifier` holds, which would otherwise drop it as unchanged. Match
  /// rooms by [id] to find the same room.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatRoom &&
          other.id == id &&
          other.type == type &&
          other.name == name &&
          other.imageUrl == imageUrl &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.unreadCount == unreadCount &&
          other.lastReadAt == lastReadAt &&
          other.pinnedAt == pinnedAt &&
          other.mutedUntil == mutedUntil &&
          mapEquals(other.metadata, metadata) &&
          listEquals(other.users, users) &&
          listEquals(other.lastMessages, lastMessages);

  @override
  int get hashCode => Object.hash(
    id,
    type,
    name,
    imageUrl,
    createdAt,
    updatedAt,
    unreadCount,
    lastReadAt,
    pinnedAt,
    mutedUntil,
  );

  @override
  String toString() => 'ChatRoom($id, ${type.name}, $name)';
}
