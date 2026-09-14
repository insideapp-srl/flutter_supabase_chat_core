import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:meta/meta.dart';

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

  /// Unique identifier, matches Supabase `auth.users.id`.
  final String id;
  final String? firstName;
  final String? lastName;
  final String? imageUrl;
  final ChatRoomRole? role;
  final Map<String, dynamic>? metadata;

  /// Epoch milliseconds.
  final int? createdAt;

  /// Epoch milliseconds.
  final int? updatedAt;

  /// Epoch milliseconds.
  final int? lastSeen;

  /// [firstName] and [lastName] joined by a space, trimmed.
  String get fullName => [
    firstName,
    lastName,
  ].where((e) => e != null && e.isNotEmpty).join(' ').trim();

  factory ChatUser.fromJson(Map<String, dynamic> json) => ChatUser(
    id: json['id'] as String,
    firstName: json['firstName'] as String?,
    lastName: json['lastName'] as String?,
    imageUrl: json['imageUrl'] as String?,
    role: json['role'] != null
        ? ChatRoomRole.values.byName(json['role'] as String)
        : null,
    metadata: json['metadata'] as Map<String, dynamic>?,
    createdAt: json['createdAt'] as int?,
    updatedAt: json['updatedAt'] as int?,
    lastSeen: json['lastSeen'] as int?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'firstName': firstName,
    'lastName': lastName,
    'imageUrl': imageUrl,
    'role': role?.name,
    'metadata': metadata,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'lastSeen': lastSeen,
  };

  ChatUser copyWith({
    String? firstName,
    String? lastName,
    String? imageUrl,
    ChatRoomRole? role,
    Map<String, dynamic>? metadata,
    int? updatedAt,
    int? lastSeen,
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
    createdAt: createdAt != null
        ? DateTime.fromMillisecondsSinceEpoch(createdAt!, isUtc: true)
        : null,
    metadata: {if (role != null) 'role': role!.name, ...?metadata},
  );

  @override
  bool operator ==(Object other) => other is ChatUser && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
