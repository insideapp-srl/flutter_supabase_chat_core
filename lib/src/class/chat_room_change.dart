import 'package:meta/meta.dart';

import 'chat_room.dart';

/// A change to the list of rooms the logged-in user is a member of, as
/// emitted by `SupabaseChatCore.roomsChanges`.
@immutable
sealed class ChatRoomChange {
  const ChatRoomChange();
}

/// A room was created, updated (e.g. it received a new message), or the
/// user was added to it.
final class ChatRoomUpserted extends ChatRoomChange {
  /// Creates an upsert change.
  const ChatRoomUpserted(this.room);

  /// The room, freshly loaded from the rooms view.
  final ChatRoom room;
}

/// A room was deleted, or the user is no longer a member of it.
final class ChatRoomRemoved extends ChatRoomChange {
  /// Creates a removal change.
  const ChatRoomRemoved(this.roomId);

  /// Id of the room that is gone.
  final String roomId;
}
