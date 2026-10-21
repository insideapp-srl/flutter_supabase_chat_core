import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:meta/meta.dart';

import '../util.dart';
import 'chat_room_role.dart';

/// Represents a user stored in the `users` table.
///
/// This is the package's own user model: `flutter_chat_core`'s [core.User]
/// only carries `id`, `name`, `imageSource`, `createdAt` and `metadata`, so it
/// cannot represent [firstName]/[lastName]/[role] on its own. Use
/// [toCoreUser] at the UI boundary (e.g. for `Chat.resolveUser`) to obtain a
/// `flutter_chat_core` [core.User].
@immutable
class ChatUser {
  /// Creates a user.
  const ChatUser({
    required this.id,
    this.firstName,
    this.lastName,
    this.imageUrl,
    this.role,
    this.metadata,
    this.createdAt,
    this.updatedAt,
    this.lastSeen,
  });

  /// Builds a user out of a `users` row (or an element of a room's embedded
  /// `users` array, which also carries the room-specific `role`).
  factory ChatUser.fromJson(Map<String, dynamic> json) => ChatUser(
    id: json['id'] as String,
    firstName: json['firstName'] as String?,
    lastName: json['lastName'] as String?,
    imageUrl: json['imageUrl'] as String?,
    role: chatRoomRoleFromName(json['role'] as String?),
    metadata: (json['metadata'] as Map?)?.cast<String, dynamic>(),
    createdAt: parseChatDate(json['createdAt']),
    updatedAt: parseChatDate(json['updatedAt']),
    lastSeen: parseChatDate(json['lastSeen']),
  );

  /// Unique identifier, matches Supabase `auth.users.id`.
  final String id;

  /// First name, if set.
  final String? firstName;

  /// Last name, if set.
  final String? lastName;

  /// Avatar URL, if set.
  final String? imageUrl;

  /// Role inside the room this user was loaded from (`null` for a plain
  /// member, or when the user wasn't loaded in the context of a room).
  final ChatRoomRole? role;

  /// Additional custom data.
  final Map<String, dynamic>? metadata;

  /// When the user was created.
  final DateTime? createdAt;

  /// When the user was last updated.
  final DateTime? updatedAt;

  /// When the user was last seen.
  final DateTime? lastSeen;

  /// [firstName] and [lastName] joined by a space, trimmed.
  String get fullName => [
    firstName,
    lastName,
  ].where((e) => e != null && e.isNotEmpty).join(' ').trim();

  /// Up to two uppercase initials from [firstName]/[lastName] (e.g. `JD`),
  /// handy for avatar placeholders. Empty when neither is set.
  String get initials => [firstName, lastName]
      .where((e) => e != null && e.trim().isNotEmpty)
      .map((e) => e!.trim()[0].toUpperCase())
      .join();

  /// Serializes this user with the same keys [ChatUser.fromJson] reads.
  Map<String, dynamic> toJson() => {
    'id': id,
    'firstName': firstName,
    'lastName': lastName,
    'imageUrl': imageUrl,
    'role': role?.name,
    'metadata': metadata,
    'createdAt': createdAt?.toUtc().toIso8601String(),
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'lastSeen': lastSeen?.toUtc().toIso8601String(),
  };

  /// Returns a copy with the given fields replaced.
  ChatUser copyWith({
    String? firstName,
    String? lastName,
    String? imageUrl,
    ChatRoomRole? role,
    Map<String, dynamic>? metadata,
    DateTime? updatedAt,
    DateTime? lastSeen,
  }) => ChatUser(
    id: id,
    firstName: firstName ?? this.firstName,
    lastName: lastName ?? this.lastName,
    imageUrl: imageUrl ?? this.imageUrl,
    role: role ?? this.role,
    metadata: metadata ?? this.metadata,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastSeen: lastSeen ?? this.lastSeen,
  );

  /// Converts this user to the [core.User] model expected by
  /// `flutter_chat_core` / `flutter_chat_ui` (e.g. `Chat.resolveUser`).
  ///
  /// [role] has no equivalent field on [core.User] and is added to
  /// `metadata['role']` instead.
  core.User toCoreUser() => core.User(
    id: id,
    name: fullName.isEmpty ? null : fullName,
    imageSource: imageUrl,
    createdAt: createdAt,
    metadata: {if (role != null) 'role': role!.name, ...?metadata},
  );

  @override
  bool operator ==(Object other) => other is ChatUser && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ChatUser($id, $fullName)';
}
