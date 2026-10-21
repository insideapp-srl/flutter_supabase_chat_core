---
id: supabase-usage
title: Usage
---

:::info
This page describes the 2.x API. Coming from 1.x? See [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md) for the old → new mapping.
:::

## Users and authentication

Users sign up with [Supabase Authentication](https://supabase.com/docs/guides/auth). The `chats.handle_new_user` trigger creates their chat profile in `chats.users`, taking the first name, last name and avatar from the sign-up metadata when present (`first_name`/`firstName`/`given_name`, `last_name`/`lastName`/`family_name`, `avatar_url`/`picture`):

```dart
await Supabase.instance.client.auth.signUp(
  email: email,
  password: password,
  data: {'first_name': 'John', 'last_name': 'Doe'},
);
```

`SupabaseChatCore.instance` keeps track of the logged-in user:

* `loggedSupabaseUser`: the Supabase Auth `User` (from `supabase_flutter`);
* `loggedUserId`: its id;
* `loggedUser`: the chat profile, a `ChatUser` (with `firstName`, `lastName`, `imageUrl`, `lastSeen`, `fullName`, `initials`), reloaded on auth state changes; `refreshLoggedUser()` reloads it on demand.

Update the profile and the avatar:

```dart
final me = SupabaseChatCore.instance.loggedUser!;
await SupabaseChatCore.instance.updateUser(
  me.copyWith(firstName: 'John', lastName: 'Doe'),
);
await SupabaseChatCore.instance.uploadUserAvatar('me.jpg', bytes);
```

List users (e.g. for a "new chat" picker) with `users()`. It's a paginated `Future`; every word of `filter` must match the first or last name:

```dart
final page = await SupabaseChatCore.instance.users(
  filter: 'jo',
  offset: 0,
  limit: 20,
  excludeLoggedUser: true,
);
```

`user(uid: id)` returns a single user. At the UI boundary, `ChatUser.toCoreUser()` converts it to the `flutter_chat_core` `User` expected by `Chat.resolveUser`.

## Rooms

### Creating rooms

```dart
// Direct room: reused if one already exists with this user.
final room = await SupabaseChatCore.instance.createRoom(otherUser);

// Group room: the caller is added as admin (see creatorRole).
final group = await SupabaseChatCore.instance.createGroupRoom(
  name: 'Product team',
  users: [bob, carol],
  imageUrl: null,
  metadata: {'topic': 'release'},
);
```

Both go through the `chats.create_room` RPC, which creates the room and its members in one transaction. A direct room is unique per pair of users **and** metadata scope: an existing one is returned when its metadata contains every entry of the requested metadata (see [Scoping](#scoping-workspaces-organizations)).

### Rooms list

`SupabaseChatRoomsController` is a `ChangeNotifier` with a paginated, searchable list of the user's rooms, kept in sync over Realtime: new rooms appear, rooms receiving messages move up with their last message and unread count updated, deleted or left rooms disappear.

```dart
final rooms = SupabaseChatRoomsController(pageSize: 20)..loadFirstPage();

ListenableBuilder(
  listenable: rooms,
  builder: (context, _) => ListView(
    children: [
      for (final room in rooms.rooms)
        ListTile(
          title: Text(room.name ?? 'Chat'),
          subtitle: Text(room.isMuted ? 'muted' : ''),
          trailing: room.unreadCount > 0
              ? Badge(label: Text('${room.unreadCount}'))
              : null,
        ),
    ],
  ),
);
```

| Member | Purpose |
|--------|---------|
| `loadFirstPage()`, `loadNextPage()`, `refresh()`, `hasMore`, `isLoading`, `error` | Pagination and state |
| `search(filter)`, `filter` | Name search (direct rooms are named after the other member). While a filter is active, Realtime only updates rooms already in the list |
| `totalUnreadCount` | Unread messages across the loaded rooms, muted rooms excluded |
| `markLocallyAsRead(roomId)` | Clear a badge right away, before the server round trip |
| `pinRoom()`, `muteRoom()`, `unmuteRoom()` | Same as `SupabaseChatCore`, updating the list at once |

Rooms are sorted with the ones the user pinned first (most recently pinned first), then by `updatedAt`, which only new messages bump. `unreadCount` is capped at 100 by the view (show "99+").

Building your own list instead? `rooms(filter:, offset:, limit:)` returns a page, `roomsChanges()` a stream of `ChatRoomUpserted`/`ChatRoomRemoved` changes, and `SupabaseChatCore.applyRoomChange(list, change)` merges one into a list.

### A single room

* `getRoom(id)` returns the room, or `null` if it doesn't exist or the user isn't a member.
* `room(id)` returns a stream that emits the room right away and on every change to it or its members, and completes when the room is deleted or the user leaves it.
* A `ChatRoom` exposes `users` (each with its per-room `role`), `member(id)`, `roleOf(id)`, `otherUser(myId)` for direct rooms, `lastMessage`, `unreadCount`, `lastReadAt`, `isPinned`/`pinnedAt` and `isMuted`/`mutedUntil` (`ChatRoom.mutedForever` when muted for ever).

### Managing rooms

| Method | Who can |
|--------|---------|
| `updateRoom(room)` | Name, avatar and metadata of a group: admins. Direct rooms: metadata only, either member |
| `addMembers(roomId, userIds, role:)` | Group admins |
| `removeMember(roomId, userId)` | Admins, or yourself |
| `leaveRoom(roomId)` | Any member |
| `setMemberRole(roomId, userId, role)` | Admins (`null` = plain member) |
| `deleteRoom(roomId)` | Group admins, or either member of a direct room. Deletes every message |
| `markRoomAsRead(roomId)` | Any member: resets `unreadCount` and flips other members' messages to `seen` |
| `pinRoom(roomId, pinned:)`, `muteRoom(roomId, duration:)`, `unmuteRoom(roomId)` | Any member, for themselves only |

A room left without members is deleted automatically. Muting is advisory: read `room.isMuted` to decide whether to notify.

## Messages

### SupabaseChatController

`SupabaseChatController` implements `flutter_chat_core`'s `ChatController`. Create one per open room, pass it to `Chat.chatController` and dispose it with the page:

```dart
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:flyer_chat_text_message/flyer_chat_text_message.dart';
import 'package:uuid/uuid.dart';

class _RoomPageState extends State<RoomPage> {
  late final _controller = SupabaseChatController(
    room: widget.room,
    onError: (error) => ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.message))),
  );

  String get _me => SupabaseChatCore.instance.loggedUserId!;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Chat(
    currentUserId: _me,
    resolveUser: (id) async =>
        (widget.room.member(id) ??
                await SupabaseChatCore.instance.user(uid: id))
            ?.toCoreUser(),
    chatController: _controller,
    onMessageSend: (text) => _controller.sendMessage(
      core.Message.text(id: const Uuid().v7(), authorId: _me, text: text),
    ),
    builders: core.Builders(
      chatAnimatedListBuilder: (context, itemBuilder) => ChatAnimatedList(
        itemBuilder: itemBuilder,
        onEndReached: _controller.loadPreviousMessages,
      ),
      textMessageBuilder:
          (context, message, index, {required isSentByMe, groupStatus}) =>
              FlyerChatTextMessage(message: message, index: index),
      // imageMessageBuilder, fileMessageBuilder, audioMessageBuilder...
    ),
  );
}
```

Constructor parameters: `room`, `pageSize` (20), `onError` (failures of background work: initial load, Realtime processing, automatic mark-as-read), `autoMarkAsRead` (true) and `chatCore` (defaults to `SupabaseChatCore.instance`).

### Loading messages

The first page loads on creation (`initialLoad` completes when done). `loadPreviousMessages()` loads the next older page using the oldest loaded `createdAt` as cursor, so pages stay stable while new messages arrive; `hasMoreMessages` tells whether there may be more. New, edited and deleted messages arrive over Realtime and are applied with `flutter_chat_ui`'s insert/update/remove animations.

### Sending

```dart
await _controller.sendMessage(
  core.Message.image(
    id: const Uuid().v7(),
    authorId: _me,
    source: upload.url,
    size: bytes.length,
  ),
);
```

* The message is inserted locally right away with status `sending`.
* `authorId` is always set to the logged-in user (RLS enforces it too), `createdAt` defaults to now, and the database sets the status to `sent`.
* The id is stored as-is, so the Realtime echo of the insert updates the local copy instead of duplicating it. Use `const Uuid().v7()`: v7 ids are time-ordered like the database's own `chats.uuid_generate_v7()`, which keeps the primary key index insert-friendly.
* On failure the local copy keeps status `error` and the exception is rethrown; `retryMessage(message)` sends it again, `deleteMessage(id)` drops it locally.

`sendMessage` also stops the typing indicator. Upload attachments first with `SupabaseChatCore.instance.uploadAsset(room, fileName, bytes)`: it returns an `UploadAssetResult` with the authenticated `url`, the detected `mimeType` and the object `path` (`<roomId>/<uuid v7>-<file name>`). Load those URLs with `SupabaseChatCore.instance.httpSupabaseHeaders` (e.g. `FlyerChatImageMessage(headers: ...)`).

`SupabaseChatCore.instance.sendMessage(message, roomId)` sends without the optimistic part, e.g. from code that doesn't use a controller.

### Read receipts

With `autoMarkAsRead` the controller calls `markRoomAsRead` once the first page is loaded and whenever another member's message arrives. The `chats.mark_room_as_read` RPC stores the read time on the membership (driving `unreadCount`) and flips the other members' messages to `seen`, which reaches their senders as Realtime updates. In a group, a message is `seen` as soon as any other member read it. Pass `autoMarkAsRead: false` and call `markAsRead()` yourself if, for example, you only want to mark rooms read while the app is in the foreground.

### Editing, reactions, pins, deletion

| Controller method | Notes |
|-------------------|-------|
| `editTextMessage(message, text)` | Author only. Sets `editedAt` and `metadata['edited'] = true`; rolled back locally on failure |
| `toggleReaction(messageId, reaction)` | Any member; atomic `chats.toggle_message_reaction` RPC. Reactions map an emoji to user ids |
| `setPinned(message, pinned:)`, `pinnedMessages` | Group admins or either member of a direct room. `pinnedMessages` is a `ValueNotifier` updated in real time, e.g. for a pinned banner |
| `deleteMessage(messageId)` | The author, or a group admin. Returns whether a message was deleted |

`SupabaseChatCore.updateMessage(message, roomId)` updates content and metadata only: status, reactions and the pinned flag have their own calls.

### Replies, search and jumping

* Set `replyToMessageId` when building a message to reply to another one.
* `resolveMessage(id)` returns a message from the loaded ones or fetches it once (cached), e.g. to render the quoted message.
* `jumpToMessage(id)` loads older pages until the message is found (at most `maxPages`, default 20) and scrolls to it.
* `SupabaseChatCore.instance.searchMessages(roomId, query)` returns the text messages containing `query` (case-insensitive), newest first.

### Typing indicator

Call `onTyping()` on every keystroke of the composer (throttling is internal) and listen to `typingUsers`, a stream of the other members currently typing (`currentTypingUsers` for the current value):

```dart
_text.addListener(() {
  if (_text.text.isNotEmpty) _controller.onTyping();
});

StreamBuilder<List<ChatUser>>(
  stream: _controller.typingUsers,
  builder: (context, snapshot) => Text(
    (snapshot.data ?? const []).isEmpty ? '' : 'typing…',
  ),
);
```

Pass `_text` to `Composer(textEditingController: _text)` through `Builders.composerBuilder`. See [Realtime](supabase-realtime.md) for how it works.

## Online status

Wrap your home page in `UserOnlineStateObserver`: it publishes the user as online while the app is in the foreground (on the web: while the window is focused), offline otherwise, and stores `lastSeen` when going offline.

```dart
MaterialApp(home: const UserOnlineStateObserver(child: HomePage()));
```

Show someone's status with `UserOnlineStatusWidget`, or listen to `SupabaseChatCore.instance.userOnlineStatus(uid)` directly:

```dart
UserOnlineStatusWidget(
  uid: user.id,
  builder: (status) => Text(
    status == UserOnlineStatus.online ? 'online' : 'last seen recently',
  ),
);
```

## Scoping (workspaces, organizations)

`SupabaseChatCoreConfig` holds the names of the schema, tables, views, channel prefixes and buckets (all named parameters with defaults matching the SQL scripts) and four hooks to keep the chats of different scopes apart without forking the package:

```dart
SupabaseChatCore.instance.setConfig(
  const SupabaseChatCoreConfig().copyWith(
    defaultRoomMetadata: () => {'workspaceId': currentWorkspaceId},
    roomsQueryFilter: (q) => q.eq('metadata->>workspaceId', currentWorkspaceId),
    roomFilter: (room) => room.metadata?['workspaceId'] == currentWorkspaceId,
    usersQueryFilter: (q) => q.eq('metadata->>workspaceId', currentWorkspaceId),
  ),
);
```

| Hook | Effect |
|------|--------|
| `defaultRoomMetadata` | Merged into the metadata of every room created by `createRoom`/`createGroupRoom` (explicit metadata wins). Direct rooms are de-duplicated per scope |
| `roomsQueryFilter` | Applied to every rooms query, including Realtime refetches |
| `usersQueryFilter` | Applied to every `users()` query |
| `roomFilter` | Rooms received over Realtime for which it returns `false` are ignored. Keep it consistent with `roomsQueryFilter` |

`usersViewName` makes `users()`/`user()` read from a view instead of `chats.users`, e.g. one exposing only the users sharing a workspace with the caller.

Hooks are evaluated on every call, so they can read state that changes at runtime. Call `setConfig` before using the instance.

:::caution
Hooks only narrow what the client asks for. If a scope is a security boundary, enforce the same rule server side with RLS policies.
:::

When you rename tables, views, buckets or `realtimeRoomChannelPrefix`, update the SQL scripts accordingly: the channel prefix is also hard-coded in the `chats.broadcast_message_change` trigger and in `chats.is_chat_member_topic`.

To work with a different `SupabaseClient` (e.g. several logged-in users in one process, as the integration tests do), create your own `SupabaseChatCore(client: ..., config: ...)`, pass it as `chatCore:` to controllers and widgets, and `dispose()` it when done.

## Error handling

Every public method of `SupabaseChatCore`, `SupabaseChatController` and `SupabaseChatRoomsController` throws a `SupabaseChatCoreException` subtype, with the original error in `cause`:

* `SupabaseChatCoreAuthException`: an operation needs a logged-in user and there isn't one;
* `SupabaseChatCoreRequestException`: the request failed (RLS, constraint, connectivity, Realtime subscription...);
* `SupabaseChatCoreStorageException`: an upload failed.

```dart
try {
  await SupabaseChatCore.instance.leaveRoom(room.id);
} on SupabaseChatCoreException catch (e) {
  // e.message names the operation, e.cause holds the PostgrestException/...
}
```

Background failures that no caller awaits are reported elsewhere: `SupabaseChatController.onError`, `SupabaseChatRoomsController.error`, and as errors on the `room()`/`roomsChanges()` streams.

## Media cleanup

Deleting a message deletes its row immediately. When it referenced a file in Supabase Storage, the `chats.queue_media_for_deletion` trigger records the object in `chats.media_pending_deletion`, because SQL alone can't delete objects from the storage backend. The [`cleanup-media`](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/supabase/functions/cleanup-media/index.ts) Edge Function drains the queue (up to 500 objects per call) through the Storage API and marks the rows as processed.

1. Deploy it: `supabase functions deploy cleanup-media`.
2. Store the project URL and a service role key in Vault, once (never commit real keys):

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'chats_project_url');
select vault.create_secret('<service-role-key>', 'chats_service_role_key');
```

3. Run `example/utils/sql/06_cleanup_media_schedule.sql`: it schedules the function every 15 minutes with `pg_cron` + `pg_net`, only when the queue isn't empty. Re-running it replaces the job.

You can also call it by hand:

```bash
curl -X POST "$SUPABASE_URL/functions/v1/cleanup-media" \
     -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
```

Without it nothing breaks: the files of deleted messages simply stay in the bucket.
