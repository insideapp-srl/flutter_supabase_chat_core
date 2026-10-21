/// Role of a [ChatUser] inside a [ChatRoom]. A plain member has no role
/// (`null`).
enum ChatRoomRole {
  /// Can rename the room, manage its members and their roles, delete it.
  admin,

  /// Reserved for app-specific moderation rules.
  moderator,
}

/// Parses a [ChatRoomRole] by name, returning `null` for `null` or unknown
/// values instead of throwing.
ChatRoomRole? chatRoomRoleFromName(String? name) {
  if (name == null) return null;
  for (final role in ChatRoomRole.values) {
    if (role.name == name) return role;
  }
  return null;
}
