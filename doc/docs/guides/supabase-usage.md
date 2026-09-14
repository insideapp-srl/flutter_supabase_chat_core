---
id: supabase-usage
title: Usage
---

:::info
Coming from 1.x (`flutter_chat_types`)? This page describes the 2.x
(`flutter_chat_core`) API. See [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md)
for the full upgrade guide.
:::

As mentioned in [How it works?](../introduction/supabase-overview.md#how-it-works), you will need to register a user using [Supabase Authentication](https://supabase.com/docs/guides/auth). If you are using Supabase Authentication as your auth provider you don't need to do anything, a trigger will create a new row in the `chats.users` table.

Every call below can throw a `SupabaseChatCoreException` (or one of its subtypes — `SupabaseChatCoreAuthException`, `SupabaseChatCoreRequestException`, `SupabaseChatCoreStorageException`) if the underlying Supabase request fails. Catch that one type instead of every possible Postgrest/Auth/Storage exception. See [Error handling](#error-handling) below.

## Update user

You can provide values like `firstName`, `imageUrl` and `lastName` if you're planning to have a screen with all users available for chat.

```dart
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

final updated = user.copyWith(
  firstName: 'John',
  imageUrl: 'https://i.pravatar.cc/300',
  lastName: 'Doe',
);

await SupabaseChatCore.instance.updateUser(updated);
```

## Supabase Chat users

Use `SupabaseChatCore.instance.users()` to get a paginated list of registered users with avatars and names. It's a `Future`, not a stream — pair it with a pagination package such as [`infinite_scroll_pagination`](https://pub.dev/packages/infinite_scroll_pagination) (see `example/lib/src/pages/users.dart`):

```dart
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

final controller = PagingController<int, ChatUser>(
  getNextPageKey: (state) =>
      state.lastPageIsEmpty ? null : (state.items?.length ?? 0),
  fetchPage: (pageKey) => SupabaseChatCore.instance.users(
    filter: filter,
    offset: pageKey,
    limit: 20,
  ),
);
```

## Starting a chat

When you have a `ChatUser` (e.g. from the `users()` list above), call either `createRoom` or `createGroupRoom`. For a group, you additionally provide a name and an optional image. Both throw `SupabaseChatCoreAuthException` if there's no logged-in user.

```dart
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

Future<void> startDirectChat(ChatUser otherUser) async {
  final room = await SupabaseChatCore.instance.createRoom(otherUser);
  // Navigate to the room, e.g. RoomPage(room: room)
}

Future<void> startGroupChat(String name, List<ChatUser> members) async {
  final room = await SupabaseChatCore.instance.createGroupRoom(
    name: name,
    users: members,
  );
}
```

## Rooms

`SupabaseChatCore.instance.rooms()` returns a paginated `Future<List<ChatRoom>>` of the current user's rooms — the same pagination pattern as `users()`. For live updates (new/updated rooms as they happen) use the `roomsUpdates()` stream and merge it into your paginated list, as `example/lib/src/pages/rooms.dart` does:

```dart
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

final controller = PagingController<int, ChatRoom>(
  getNextPageKey: (state) =>
      state.lastPageIsEmpty ? null : (state.items?.length ?? 0),
  fetchPage: (pageKey) => SupabaseChatCore.instance.rooms(
    filter: filter,
    offset: pageKey,
    limit: 20,
  ),
);

// Merge realtime updates into the paginated list already loaded:
SupabaseChatCore.instance.roomsUpdates().listen((updatedRooms) {
  final merged = SupabaseChatCore.updateRoomList(
    controller.items ?? [],
    updatedRooms,
  );
  // apply `merged` back to the paging controller state
});
```

A `ChatRoom`'s name and image come either from the ones you provided for a group, or from the other participant's name/avatar for a direct room. See [Security Rules](supabase-security-rls.md) for how rooms are filtered per user.

## Messages

Messages are managed per-room by `SupabaseChatController`, which implements `flutter_chat_core`'s `ChatController` and keeps itself in sync with Supabase Realtime. Create one per open room and pass it straight to `Chat.chatController`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.room});

  final ChatRoom room;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  late final SupabaseChatController _chatController;

  @override
  void initState() {
    super.initState();
    _chatController = SupabaseChatController(
      room: widget.room,
      // Optional: background failures (initial load, realtime processing)
      // aren't awaited by any caller, so surface them here instead.
      onError: (error) => debugPrint('Chat error: $error'),
    );
  }

  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }

  Future<core.User?> _resolveUser(String id) async {
    for (final user in widget.room.users) {
      if (user.id == id) return user.toCoreUser();
    }
    final fetched = await SupabaseChatCore.instance.user(uid: id);
    return fetched?.toCoreUser();
  }

  @override
  Widget build(BuildContext context) => Chat(
        currentUserId: SupabaseChatCore.instance.loggedSupabaseUser!.id,
        resolveUser: _resolveUser,
        chatController: _chatController,
        onMessageSend: (text) {
          final message = core.Message.text(
            id: const Uuid().v7(),
            authorId: SupabaseChatCore.instance.loggedSupabaseUser!.id,
            text: text,
          );
          _chatController.sendMessage(message);
        },
        builders: core.Builders(
          // one builder per message type you use — text/image/file/...
          // via the `flyer_chat_*_message` packages. See
          // `example/lib/src/pages/room.dart` for a full setup.
        ),
      );
}
```

`loadPreviousMessages()`, `onTyping()`/`endTyping()` and `deleteMessage(messageId)` are available directly on the controller. `flutter_chat_ui` no longer ships built-in renderers for images/files (only a minimal text fallback) — add the `flyer_chat_*_message` package for each message type you use, see [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md).

### Send a message

Build a `flutter_chat_core` `Message` yourself (`Message.text`, `Message.image`, `Message.file`, ...) with your own `id` — use `const Uuid().v7()`, not `.v4()`: v7 ids are time-ordered, matching the database's own id generator, which keeps `chats.messages`' primary key index insert-friendly. Then call `_chatController.sendMessage`:

```dart
final message = core.Message.text(
  id: const Uuid().v7(),
  authorId: SupabaseChatCore.instance.loggedSupabaseUser!.id,
  text: text,
);
await _chatController.sendMessage(message);
```

`authorId`, `createdAt` and `updatedAt` are set for you. The message appears in the UI immediately (`_chatController` inserts it locally before the request even completes) — Supabase stores your exact `id`, so when Realtime echoes the insert back it's recognized as already present instead of appearing twice. If the request fails, the optimistic message is removed again and the error rethrown. Prefer calling `SupabaseChatCore.instance.sendMessage(message, room.id)` directly only if you're not using a `SupabaseChatController` for this room at all.

### Update a message

Take a message from `_chatController.messages`, `copyWith` the change, and call `SupabaseChatCore.instance.updateMessage`:

```dart
final updated = message.copyWith(status: core.MessageStatus.seen);
await SupabaseChatCore.instance.updateMessage(updated, room.id);
```

### Delete a message

Prefer `_chatController.deleteMessage(messageId)` — it removes the message from Supabase and, if that succeeds, also removes it locally so the UI updates immediately.

## `loggedSupabaseUser`

`SupabaseChatCore.instance.loggedSupabaseUser` is a shortcut to see which user is currently logged in through Supabase Authentication. The returned `User` type comes from `supabase_flutter` — **it is not the same as `ChatUser`** (this package's own user type, with `firstName`/`lastName`/`role`) or `flutter_chat_core`'s `User`. `SupabaseChatCore.instance.loggedUser` gives you the corresponding `ChatUser` instead, kept in sync automatically as auth state changes.

## Error handling

Every `SupabaseChatCore` and `SupabaseChatController` method can throw a `SupabaseChatCoreException`:

- `SupabaseChatCoreAuthException` — no logged-in user for an operation that requires one.
- `SupabaseChatCoreRequestException` — the Supabase/Postgres request itself failed (RLS permission denied, constraint violation, connectivity, ...).
- `SupabaseChatCoreStorageException` — uploading a chat asset (image, file, avatar) failed.

```dart
try {
  await SupabaseChatCore.instance.sendMessage(message, room.id);
} on SupabaseChatCoreException catch (e) {
  // e.cause holds the original PostgrestException/AuthException/... if any
}
```

`SupabaseChatController`'s background operations (initial message load, realtime insert/update/delete) aren't awaited by any caller — pass an `onError` callback to its constructor to observe failures there instead; calls you await directly (`loadPreviousMessages()`, `deleteMessage()`, ...) throw normally.
