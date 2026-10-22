# Migrating from 1.x to 2.x

`flutter_supabase_chat_core` 2.0.0 moves from
[`flutter_chat_types`](https://pub.dev/packages/flutter_chat_types) (the
model package behind `flutter_chat_ui` 1.x) to
[`flutter_chat_core`](https://pub.dev/packages/flutter_chat_core) (the model
package behind the rewritten `flutter_chat_ui` 2.x), and redesigns the
database: uuid ids, `timestamptz` dates, a `room_members` table, partitioned
messages, Realtime Broadcast and stricter RLS.

Both sides must move together: **a 1.x app does not work against a 2.x
database, and a 2.x app does not work against a 1.x database.** Plan a
maintenance window (see [Database migration](#database-migration)).

The [example app](example) is a complete 2.x integration; use it as a
reference while porting.

## Dependencies

```yaml
dependencies:
  flutter_supabase_chat_core: ^2.0.0-rc.2
  flutter_chat_core: ^2.9.0        # replaces flutter_chat_types
  flutter_chat_ui: ^2.11.1         # if you use the UI (2.x API)
  flyer_chat_text_message: ^2.6.0  # one package per message type you render
  flyer_chat_image_message: ^2.3.0
  flyer_chat_file_message: ^2.4.0
  uuid: ^4.5.1
```

Minimum SDKs are now `Dart >=3.8.0` and `Flutter >=3.32.0`.

`flutter_chat_ui` 2.12.0 moved its `Composer` to the experimental
`material_ui` package, which crashes inside a standard `Scaffold` ("No
Material widget found"); the example pins `'>=2.11.1 <2.12.0'`. For the same
reason, since `flutter_chat_core` 2.9.1 `ChatTheme.fromThemeData` takes a
`material_ui` theme, not Flutter's `ThemeData`: build the `ChatTheme`
yourself (see `example/lib/src/theme/app_theme.dart`).

## Dart API

### Mapping

| 1.x | 2.x |
|-----|-----|
| `types.Room` | `ChatRoom` (`id` is a uuid string, `createdAt`/`updatedAt` are `DateTime?`, members in `users` each with its per-room `role`). New: `unreadCount`, `lastReadAt`, `pinnedAt`/`isPinned`, `mutedUntil`/`isMuted`, `ChatRoom.mutedForever`, `member()`, `roleOf()`, `otherUser()`, `lastMessage` |
| `types.RoomType` | `ChatRoomType` (`direct`, `group`) |
| `types.Role` | `ChatRoomRole` (`admin`, `moderator`; `null` = plain member). Roles are per room |
| `types.User` | `ChatUser` (`DateTime?` dates, `fullName`, `initials`). Convert with `toCoreUser()` for `Chat.resolveUser` (`role` goes to `metadata['role']`) |
| `types.Message` and subclasses | `flutter_chat_core`'s sealed `Message` (`Message.text`, `.image`, `.file`, `.audio`, ...). A message carries `authorId`, not an embedded `author` |
| `types.PartialText` / `PartialImage` / `PartialFile` / `PartialCustom` | Build a full `core.Message` with a client id: `core.Message.text(id: const Uuid().v7(), authorId: me, text: text)` |
| Epoch milliseconds (`int`) dates | `DateTime` (UTC); columns are `timestamptz` |
| `SupabaseChatCoreConfig('chats', 'rooms', ...)` (9 positional args) | `SupabaseChatCoreConfig(...)` with **named** parameters, all with defaults, plus `copyWith` |
| `config.realtimeChatTypingUserPrefixChannel` (`'chat-user-typing-'`) | `config.realtimeRoomChannelPrefix` (`'chats:room:'`): one private Broadcast channel per room for messages **and** typing |
| – | New config: `roomMembersTableName`, `usersViewName`, `userAvatarsBucket`, scoping hooks `defaultRoomMetadata`, `roomsQueryFilter`, `usersQueryFilter`, `roomFilter` |
| `SupabaseChatCore.instance` (private constructor) | Still `SupabaseChatCore.instance`; you can also create `SupabaseChatCore(client: ..., config: ...)` and `dispose()` it |
| `SupabaseChatCore.instance.config = ...` / `setConfig()` | `setConfig()` (`config` is now a getter) |
| `roomsUpdates()` + `SupabaseChatCore.updateRoomList(list, newRooms)` | `roomsChanges()` (`ChatRoomUpserted` / `ChatRoomRemoved`) + `SupabaseChatCore.applyRoomChange(list, change)`, or simply `SupabaseChatRoomsController` |
| `rooms({filter, offset, limit})` | Same, with non-nullable `offset`/`limit`. Pinned rooms come first, and a page now holds exactly `limit` rooms (1.x returned `limit + 1`) |
| `room(roomId)`, `getRoom(roomId)` | Same, returning `ChatRoom`. The stream also follows member changes and completes when the room is deleted or you leave it |
| `createRoom(types.User, {metadata})` | `createRoom(ChatUser, {metadata})`, through the `chats.create_room` RPC: an existing direct room is reused (per pair and metadata scope) |
| `createGroupRoom({creatorRole: types.Role.admin, users: List<types.User>, ...})` | `createGroupRoom({creatorRole: ChatRoomRole.admin, users: List<ChatUser>, ...})`, through the same RPC |
| `updateRoom(types.Room)` (could also change members) | `updateRoom(ChatRoom)` changes name, avatar and metadata only. Members: `addMembers()`, `removeMember()`, `leaveRoom()`, `setMemberRole()` |
| `deleteRoom(roomId)` | Same (group rooms: admins only) |
| `users({filter, offset, limit})` | Same plus `excludeLoggedUser`; every word of `filter` must match the first or last name |
| `user(uid:)`, `updateUser(types.User)` | `user(uid:)`, `updateUser(ChatUser)` |
| `loggedUser` (`types.User?`) | `loggedUser` (`ChatUser?`), plus `loggedUserId` and `refreshLoggedUser()` |
| `sendMessage(dynamic partialMessage, roomId)` | `SupabaseChatController.sendMessage(message)` (optimistic), or `SupabaseChatCore.sendMessage(core.Message, roomId)` |
| `updateMessage(types.Message, roomId)` | `updateMessage(core.Message, roomId)`: content and metadata only. Status, reactions and the pinned flag go through `markRoomAsRead()`, `toggleReaction()`, `setMessagePinned()` |
| `deleteMessage(roomId, messageId)` | Same on `SupabaseChatCore` |
| `uploadAsset(types.Room, name, bytes)` | `uploadAsset(ChatRoom, name, bytes)`; `UploadAssetResult` gained `path` |
| `getAssetUrl(path)`, `generateRoomAssetPath(types.Room, name)` | `getAssetUrl(path, {bucket})`, `generateRoomAssetPath(ChatRoom, name)` (`<roomId>/<uuid v7>-<sanitized name>`) |
| – | New: `uploadUserAvatar()`, `markRoomAsRead()`, `pinRoom()`, `muteRoom()`, `unmuteRoom()`, `messages(roomId, before:, limit:)`, `message()`, `pinnedMessages()`, `searchMessages()`, `toggleReaction()`, `setMessagePinned()` |
| `fetchUser()`, `processRoomRow()`, `processRoomsRows()` (`util.dart`) | Removed: the `rooms_l` view embeds members, use `ChatRoom.fromJson(row, currentUserId: uid)`. `util.dart` now exports `parseChatDate`, `formatChatDate`, `messageFromRow`, `messageToRow` |
| `SupabaseChatController({pageSize = 10, required types.Room room})` | `SupabaseChatController({required ChatRoom room, pageSize = 20, onError, autoMarkAsRead = true, chatCore})` |
| `controller.messages` (`Stream<List<types.Message>>`) | The controller **is** a `ChatController`: pass it to `Chat.chatController`. `messages` is the current `List<core.Message>` |
| `controller.loadPreviousMessages()` (page number) | Same name, cursor-based (`hasMoreMessages`, `initialLoad`) |
| `controller.deleteMessage(roomId, messageId)` | `controller.deleteMessage(messageId)` |
| `controller.typingUsers` (`Stream<List<types.User>>`) | `Stream<List<ChatUser>>`, plus `currentTypingUsers` |
| `onTyping()` / `endTyping()` over **Presence** | Same methods, over **Broadcast** (throttled), see below |
| – | New on the controller: `retryMessage`, `editTextMessage`, `toggleReaction`, `setPinned`, `pinnedMessages`, `resolveMessage`, `jumpToMessage`, `markAsRead`, `inMemoryController` |
| `UserOnlineStateObserver`, `UserOnlineStatusWidget` | Same, with an optional `chatCore:` |
| Raw `PostgrestException`/`StorageException`, `Future.error('User does not exist')`, silent no-ops without a user | `SupabaseChatCoreException` (`...AuthException`, `...RequestException`, `...StorageException`) with the original error in `cause` |

### Rooms list

```dart
// 1.x
SupabaseChatCore.instance.roomsUpdates().listen((rooms) {
  setState(() => _rooms = SupabaseChatCore.updateRoomList(_rooms, rooms));
});

// 2.x, by hand
SupabaseChatCore.instance.roomsChanges().listen((change) {
  setState(() => _rooms = SupabaseChatCore.applyRoomChange(_rooms, change));
});

// 2.x, with pagination, search and unread total
final rooms = SupabaseChatRoomsController()..loadFirstPage();
ListenableBuilder(listenable: rooms, builder: (context, _) => ...);
```

### Conversation

```dart
// 1.x
StreamBuilder<List<types.Message>>(
  stream: _chatController.messages,
  builder: (context, snapshot) => Chat(
    messages: snapshot.data ?? [],
    user: SupabaseChatCore.instance.loggedUser!,
    onSendPressed: (partial) =>
        SupabaseChatCore.instance.sendMessage(partial, room.id),
  ),
);

// 2.x
Chat(
  currentUserId: SupabaseChatCore.instance.loggedUserId!,
  resolveUser: (id) async => room.member(id)?.toCoreUser(),
  chatController: _chatController,
  onMessageSend: (text) => _chatController.sendMessage(
    core.Message.text(
      id: const Uuid().v7(),
      authorId: SupabaseChatCore.instance.loggedUserId!,
      text: text,
    ),
  ),
  builders: core.Builders(
    chatAnimatedListBuilder: (context, itemBuilder) => ChatAnimatedList(
      itemBuilder: itemBuilder,
      onEndReached: _chatController.loadPreviousMessages,
    ),
    textMessageBuilder:
        (context, message, index, {required isSentByMe, groupStatus}) =>
            FlyerChatTextMessage(message: message, index: index),
  ),
);
```

Use `const Uuid().v7()` for message ids: the id is stored as-is, so the
controller recognizes the Realtime echo of its optimistic copy, and v7 ids are
time-ordered like the database's own default. A failed send keeps the message
with status `error` (`retryMessage` sends it again) and rethrows.

### Read receipts and link previews

- 1.x marked messages `seen` from `onMessageVisibilityChanged`. In 2.x the
  controller calls `chats.mark_room_as_read` for you (once the first page is
  loaded and on every incoming message) unless you pass
  `autoMarkAsRead: false`; it resets the room's `unreadCount` and flips the
  other members' messages to `seen`. Don't update `status` with
  `updateMessage`: it ignores it.
- Automatic link preview fetching (`onPreviewDataFetched`) has no
  counterpart: `linkPreviewData` is stored and read if you fill it yourself.

### Typing indicator

1.x tracked typing with Realtime **Presence** on `chat-user-typing-<roomId>`.
Presence `track()` calls are rate-limited and the channel was dropped while
typing ([#38](https://github.com/insideapp-srl/flutter_supabase_chat_core/issues/38)).
2.x sends `typing` **Broadcast** events on the room's private channel
`chats:room:<roomId>`: at most one every 2 s while typing, a "stopped" event
after 3 s of inactivity or on send, and receivers expire a user after 5 s
without events. Keep calling `onTyping()` on every keystroke; the throttling is
internal.

## Database migration

`example/utils/sql/01_database_schema.sql` detects the 1.x schema
(`chats.rooms.id` is `bigint`) and migrates it; on a fresh database it creates
the 2.x schema, and on a 2.x one it does nothing.

### What changes

- `chats.rooms.id`, `chats.messages.id` and `chats.messages."roomId"` become
  `uuid` (default `chats.uuid_generate_v7()`, time-ordered). `chats.users.id`
  is untouched (it matches `auth.users.id`). The old-to-new room id mapping
  is kept in `chats.room_id_migration_map` until the attachments are moved
  (step 9).
- Dates become `timestamptz` (`createdAt`, `updatedAt`, `lastSeen`).
- `chats.rooms."userIds"`/`"userRoles"` become rows of
  `chats.room_members` (`roomId`, `userId`, `role`, `lastReadAt`,
  `pinnedAt`, `mutedUntil`). Every member's `lastReadAt` is set to the
  migration time, so nobody gets a flood of unread badges.
- `chats.messages` columns follow `flutter_chat_core` names (`uri` →
  `source`, `waveForm` → `waveform`, `previewData` → `linkPreviewData`,
  `repliedMessage->>'id'` → `replyToMessageId`), plus `reactions` and
  `pinned`. `remoteId`, `isLoading`, `showStatus`, `repliedMessage` are not
  carried over.
- `chats.messages` becomes a table partitioned by week on `createdAt`
  (`pg_partman`, maintained hourly by `pg_cron`, no retention). Weekly
  partitions start 4 weeks back; older history goes to the default partition
  `chats.messages_default` (split it later with
  `partman.partition_data_proc()` if you want).
- The `rooms."lastMessages"` snapshots are rebuilt from the migrated
  messages; the rooms' `updatedAt` (list order) is kept.
- The 1.x tables are renamed to `chats.users_backup_<ts>`,
  `chats.rooms_backup_<ts>`, `chats.messages_backup_<ts>` and **kept**.
  Their RLS policies are dropped: RLS stays enabled, so they are closed to
  `anon`/`authenticated`.
- RLS is stricter: rooms are created only through `chats.create_room`,
  nobody can add themselves to a room, messages can only be sent as yourself
  and edited by their author, deletions are limited to the author (or a group
  admin), group management is admin-only. Private Realtime channels are
  authorized by policies on `realtime.messages`.
- `updatedAt` of a room is only bumped by new messages (not by edits,
  reactions or read receipts), so reading a chat no longer reorders lists.

### Steps

1. **Check the prerequisites.** `pg_partman` and `pg_cron` must be available
   (the script creates them), and Realtime must support Broadcast from
   Database (Supabase cloud; self-hosted `supabase/realtime` >= v2.33).
2. **Check the roles.** 2.x only accepts `admin` and `moderator` (or `NULL`)
   as roles, enforced by a `CHECK` constraint; 1.x allowed any
   `types.Role` value. The migration turns any other role (`agent`, `user`,
   ...) into a plain member (`NULL`). If this returns rows you want to keep
   elevated, map them to `admin`/`moderator` before migrating:

   ```sql
   SELECT id, role FROM chats.users WHERE role NOT IN ('admin', 'moderator');
   SELECT id, r.key, r.value FROM chats.rooms, jsonb_each_text("userRoles") r
   WHERE r.value NOT IN ('admin', 'moderator');
   ```

3. **Back up the database** (`pg_dump`, or a Supabase backup). The script
   keeps the old tables, but a dump is the only way back.
4. **Start the maintenance window**: stop the 1.x clients (or make sure they
   can't reach the database) until the 2.x app is released.
5. **Run the scripts in order**: `01`, `02`, `03`, `04`, `05`, `99`, with
   `example/utils/prepare.sh`/`prepare.ps1` (psql) or the commands printed by
   `supabase_prepare.sh`/`.ps1` (`supabase db query --linked`). `01` prints a
   `NOTICE` for every backup table it keeps. If you use custom names in
   `SupabaseChatCoreConfig`, adapt the scripts first.
6. **Verify the data** against the backups (replace `<ts>`):

   ```sql
   SELECT (SELECT count(*) FROM chats.users_backup_<ts>)    AS users_v1,
          (SELECT count(*) FROM chats.users)                 AS users_v2,
          (SELECT count(*) FROM chats.rooms_backup_<ts>)     AS rooms_v1,
          (SELECT count(*) FROM chats.rooms)                 AS rooms_v2,
          (SELECT count(*) FROM chats.messages_backup_<ts>)  AS messages_v1,
          (SELECT count(*) FROM chats.messages)              AS messages_v2,
          (SELECT sum(cardinality("userIds")) FROM chats.rooms_backup_<ts>) AS members_v1,
          (SELECT count(*) FROM chats.room_members)          AS members_v2;
   ```

   A member id repeated in a 1.x `userIds` array becomes a single
   `room_members` row, so `members_v2` can be lower than `members_v1`.
7. **Self-hosted Realtime**: if you restored or reset the database while
   Realtime was running, restart the Realtime container: its Postgres Changes
   poller can stay degraded and silently stop delivering room updates
   (`tool/local_db.sh` does the same locally).
8. **Optional: media cleanup.** Deploy the `cleanup-media` Edge Function and
   run `06_cleanup_media_schedule.sql` (see the README, "Media cleanup"), so
   the files of deleted messages are removed from Storage.
9. **Move the 1.x attachments** to the new room folders (see "Attachments
   uploaded by 1.x" below). It can also run after the window: until then
   the old URLs keep working.
10. **Release the 2.x app** and end the maintenance window.
11. **Drop the backups** when you're satisfied, messages first (their old
    foreign keys point at the other backups):

    ```sql
    DROP TABLE chats.messages_backup_<ts>;
    DROP TABLE chats.rooms_backup_<ts>;
    DROP TABLE chats.users_backup_<ts>;
    ```

### Attachments uploaded by 1.x

Files uploaded by 1.x live under `chats_assets/<old numeric room id>/...`,
and right after the migration the messages' `source` URLs still point there.
They keep working: the storage policies resolve the old folders through
`chats.room_id_migration_map` (`chats.is_chat_member_path`).

`example/utils/migrate_storage_uuids.sh` (or `.ps1` on Windows) moves them to
`chats_assets/<room uuid>/...`, so every attachment follows the 2.x layout
and the map can go:

```bash
export SUPABASE_SERVICE_ROLE_KEY=...   # service role (or secret) key
./migrate_storage_uuids.sh -h <host> -p <port> -d postgres -U postgres \
    -a https://<project-ref>.supabase.co -n   # dry run: what would move
./migrate_storage_uuids.sh -h <host> -p <port> -d postgres -U postgres \
    -a https://<project-ref>.supabase.co
```

```powershell
$env:SUPABASE_SERVICE_ROLE_KEY = '...'
.\migrate_storage_uuids.ps1 -hostname <host> -port <port> -database postgres -user postgres `
    -apiUrl https://<project-ref>.supabase.co -dryRun
```

For a self-hosted instance pass its API (Kong) URL. For each room the script
copies the objects (Storage API, server side), rewrites the room's URLs in
one transaction (`messages.source`, `rooms."imageUrl"`; the `lastMessages`
snapshot follows by trigger) and only then deletes the old objects. A
failure stops it without losing anything: run it again and it resumes. The
apps receive the new URLs over Realtime; a file opened from an old URL in
the meantime fails until the message is reloaded. When no room is left it
drops `chats.room_id_migration_map` (asking first, `-y`/`-yes` to skip the
question). Attachments of deleted rooms have nothing pointing at them: the
script moves them as well, delete them yourself if you don't need them.

### Known limitations of the migration

- Message ids are regenerated; `replyToMessageId` is remapped to the new ids.
  A reply whose original message no longer exists gets `NULL`.
- 1.x accepted any role text: only `admin` and `moderator` survive (on
  `chats.users` and on the room members), any other value (`agent`, `user`,
  ...) becomes a plain member (`NULL`).
- 1.x `channel` rooms have no 2.x counterpart: `ChatRoom.fromJson` reads an
  unknown type as `group`.
- Only the exact 1.x shape and fresh databases are recognized. A database in
  some other, partially migrated shape must be reconciled by hand first.

## Checklist

1. Update the dependencies (`flutter_chat_core`, `flutter_chat_ui` 2.x,
   `flyer_chat_*_message`, `uuid`).
2. Replace `types.Room`/`types.User`/`types.Role` with `ChatRoom`/`ChatUser`/
   `ChatRoomRole`, and `Partial*` messages with `core.Message.*` built with
   `const Uuid().v7()` ids.
3. Switch dates from epoch milliseconds to `DateTime`.
4. Replace `roomsUpdates()`/`updateRoomList` with
   `SupabaseChatRoomsController` or `roomsChanges()`/`applyRoomChange`.
5. Pass `SupabaseChatController` to `Chat.chatController`, wire
   `resolveUser`, `onMessageSend` and `builders`; drop your "seen" tracking.
6. Move member changes from `updateRoom` to `addMembers`/`removeMember`/
   `leaveRoom`/`setMemberRole`.
7. Rename `realtimeChatTypingUserPrefixChannel` to `realtimeRoomChannelPrefix`
   and switch `SupabaseChatCoreConfig` to named parameters, if you customized
   it.
8. Catch `SupabaseChatCoreException` instead of Supabase exceptions.
9. Migrate the database during a maintenance window, verify, then release.
10. Move the 1.x attachments with `migrate_storage_uuids.sh`/`.ps1`.
