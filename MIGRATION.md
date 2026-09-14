# Migrating from 1.x to 2.x

`flutter_supabase_chat_core` 2.0.0 moves from
[`flutter_chat_types`](https://pub.dev/packages/flutter_chat_types) (the
model package behind `flutter_chat_ui` 1.x) to
[`flutter_chat_core`](https://pub.dev/packages/flutter_chat_core) (the model
package behind Flyer Chat's rewritten `flutter_chat_ui` 2.x). It's a
different package, not a new major version of the same one, and it changed
its data model completely. This guide covers what changed and how to update
your app.

If you just want to see a complete, working v2 integration, read the
`example/` project — it's the same demo app as before, ported to v2.

## Database: one script, init or migrate, plus message partitioning

`chats.messages` columns are renamed to match `flutter_chat_core`'s v2 field
names directly (`uri` → `source`, `waveForm` → `waveform`, `previewData` →
`linkPreviewData`, `repliedMessage` → `replyToMessageId`), instead of
carrying the old v1 (`flutter_chat_types`) names forever behind a
translation layer. `lib/src/util.dart`'s `messageFromRow`/`messageToRow`
now map the table close to 1:1 — only stringifying `id`/`authorId`,
converting `duration` (stored in ms) and normalizing a legacy
`linkPreviewData` shape.

`example/utils/sql/01_database_schema.sql` is now a single, idempotent,
self-detecting script — the same file both bootstraps a fresh database and
migrates an existing v1 (`flutter_chat_types`) one, so there's nothing to
choose between:

- `chats.messages` missing → creates the v2 schema from scratch.
- `chats.messages` has v1 columns (`uri`, ...) → renames them to v2 in place.
- `chats.messages` isn't partitioned yet → converts it to partitioned (see
  below), for both of the above cases and for an already-v2 table.
- Already v2 and partitioned → no-op, safe to re-run.

Run it (and re-run `05_database_view.sql` after it) **during a maintenance
window** if you're migrating from v1 or converting an existing table to
partitioned — both rewrite `chats.messages` (the app must be on
`flutter_supabase_chat_core` 2.x once this runs — a v1 client will break
against the renamed columns):

```bash
psql -U <user> -h <host> -p <port> -d <database> -f example/utils/sql/01_database_schema.sql
psql -U <user> -h <host> -p <port> -d <database> -f example/utils/sql/05_database_view.sql
```

The v1→v2 column rename step:

- Renames `uri`/`waveForm`/`previewData` to `source`/`waveform`/`linkPreviewData` (`RENAME COLUMN`, no data touched).
- Adds `replyToMessageId text` and backfills it from the old `repliedMessage->>'id'`.
- Adds the new `reactions jsonb` and `pinned boolean` columns.
- Leaves `remoteId`, `isLoading`, `showStatus` and `repliedMessage` in place,
  unused (no v2 equivalent) — the script does **not** drop them, so it stays
  non-destructive; drop them yourself once you're sure nothing else reads
  them (see the commented block in the script).

Re-running `05_database_view.sql` recreates `chats.messages_l` against the
new column names and drops the now-unnecessary `author`/`room` joins (v2
messages only carry `authorId`, not an embedded author).

Nothing in `02_database_trigger.sql` or `03_database_policy.sql` needs to
change (the last-message trigger rebuilds `chats.rooms."lastMessages"` from
`chats.messages` dynamically via `to_jsonb(m)`, so it picks up the new
column names automatically — existing snapshots just keep old key names
until the next message in that room refreshes them; row-level triggers and
RLS *policies* defined on a partitioned parent table apply to all of its
partitions automatically on PG13+, which Supabase self-hosted already
ships). The RLS **enabled flag** is a different story — see below.

### Message partitioning (pg_partman)

`chats.messages` is now a native `PARTITION BY RANGE ("createdAt")` table,
managed by [pg_partman](https://github.com/pgpartman/pg_partman) with
**weekly** partitions and **no automatic retention** — chat history is kept
forever, partitioning is purely to keep indexes/vacuum/queries scalable as
history grows. `"createdAt"` is stored as epoch milliseconds (not a native
timestamp), which pg_partman handles directly via `p_epoch => 'milliseconds'`
— no column type change needed.

This requires the `pg_partman` and `pg_cron` extensions (both ship in
Supabase's self-hosted Postgres image). The script schedules an hourly
`pg_cron` job (`partman-run-maintenance`) that pre-creates upcoming weekly
partitions — Supabase self-hosted doesn't run pg_partman's own background
worker, so `pg_cron` stands in for it.

Practical implications:

- The primary key is now composite (`id`, `"createdAt"`) instead of just
  `id` — Postgres requires the partition key in every unique/primary key
  index. Nothing else references `messages.id` via foreign key, so this is
  safe.
- Converting an existing (non-partitioned) `chats.messages` table rewrites
  it: the old table is renamed to `chats.messages_pre_partition` and kept
  around (not dropped) as a backup — verify row counts match, then
  `DROP TABLE chats.messages_pre_partition` yourself once satisfied.
- The `supabase_realtime` publication now includes `chats.messages` **without**
  `ONLY` (a partitioned parent never holds rows itself — the previous
  `ADD TABLE ONLY` would have published nothing once partitioned).
- Want a different interval (e.g. `monthly`) or a retention window instead of
  keeping everything forever? Adjust the `partman.create_parent(...)` call
  and the `partman.part_config` update in `01_database_schema.sql`.
- **Enabling RLS on a partitioned table does not recurse to partitions
  created afterwards** (unlike indexes and row-level triggers, which
  Postgres does propagate automatically) — confirmed the hard way via
  Supabase's own database linter flagging every `chats.messages_p...`
  partition as "RLS disabled". `chats.ensure_messages_partitions_rls()`
  (called right after `partman.create_parent(...)`, and from the hourly
  `pg_cron` job alongside `partman.run_maintenance_proc()`) enables RLS on
  any partition that doesn't have it yet — including ones pg_partman
  creates on its own schedule going forward. If you already ran an earlier
  version of this script, re-run it (or just call
  `SELECT chats.ensure_messages_partitions_rls();` yourself) and check the
  Supabase linter/Advisors page to confirm no partitions are flagged.

### Room/message ids are now uuid

`chats.rooms.id` and `chats.messages.id` (and `chats.messages."roomId"`) are
`uuid` now, generated by `chats.uuid_generate_v7()` — a time-ordered UUID
(RFC 9562 UUIDv7), not a fully random one, so ids stay roughly sequential
like the old bigint identities and don't fragment `chats.messages`'
partitioned indexes on insert the way a random UUID (`gen_random_uuid()`,
UUIDv4) would. `chats.users.id` is untouched — it must keep matching
`auth.users.id`. `is_chat_member(room_id ...)` and the `chats_assets` storage
policies' `(storage.foldername(name))[1]::...` cast move from `bigint` to
`uuid` accordingly (in `03_database_policy.sql`/`04_storage.sql`).

`ChatRoom.id`/`Message.id` were already `String` on the Dart side, so this
is mostly transparent — the one required client change is
`SupabaseChatController._messagesQuery()`'s `int.parse(_room.id)`, which is
gone (a uuid string isn't parseable as an int). If your own code does
anything similar with a room/message id, drop it too.

Converting an existing `chats.rooms`/`chats.messages` table (bigint ids)
rewrites it the same way the partitioning conversion does: the old table is
renamed to a `..._backup_<timestamp>` table and kept around (not dropped),
new uuids are generated per row, and `chats.messages."roomId"` is remapped
to match its room's new id via `chats.room_id_migration_map` (old id → new
id), built while converting `chats.rooms` in that same run. Verify row
counts, then drop the backup tables yourself once satisfied.

**Storage objects need a separate move.** `chats_assets` paths are
`<roomId>/<uuid>-<filename>` — after this migration, files uploaded before
it are still under the *old* numeric room id folder, and any access to them
now errors (the storage RLS policy casts that path segment to `uuid`, so
`'<old id>'::uuid` raises an error, not just a permission denial). SQL can't
rename objects in the storage backend, so run this once, during the same
maintenance window, right after `01_database_schema.sql`:

```bash
example/utils/migrate_storage_uuids.sh   # or .ps1 on Windows
```

It reads `chats.room_id_migration_map` and moves each `chats_assets/<old
id>` folder to `chats_assets/<new id>` via the Supabase CLI's Storage API
(`supabase storage mv`). Safe to run even if there's nothing to move (skips
rooms with no storage objects). `chats.room_id_migration_map` isn't exposed
via PostgREST and is otherwise unused — drop it yourself once you've
confirmed the move worked.

This also enables **optimistic message sending**: build a message with
`const Uuid().v7()` as its id (not `.v4()` — same time-ordering reasoning as
above) and call `SupabaseChatController.sendMessage(message)` instead of
`SupabaseChatCore.instance.sendMessage(message, roomId)` directly. The
controller inserts it locally immediately, and since Supabase stores your
exact id, Realtime's echo of the insert is recognized as already present
instead of appearing as a duplicate. See
[`SupabaseChatController` now implements `ChatController`](#supabasechatcontroller-now-implements-chatcontroller)
below.

## Package API changes

### `types.Room` → `ChatRoom`

`flutter_chat_core` v2 dropped the concept of a room/conversation entirely —
it only models messages and users. `flutter_supabase_chat_core` now defines
its own `ChatRoom` (and `ChatRoomType`) to keep that feature: groups,
direct messages, last-message preview, etc. still work the same way, just
under a package-owned type instead of a re-exported one.

### `types.User` → `ChatUser`

`flutter_chat_core`'s `User` only has `id`, `name`, `imageSource`,
`createdAt`, `metadata` — no `firstName`/`lastName`/`role`. Those fields
matter for this package's user list/room logic and match the existing
`chats.users` schema, so they now live on a package-owned `ChatUser`
instead. Convert to a `flutter_chat_core` `User` at the UI boundary with
`chatUser.toCoreUser()` (`role` is folded into `metadata['role']`).

### `types.Message` → `flutter_chat_core`'s `Message`

`Message` is now a sealed class with one constructor per type
(`Message.text`, `Message.image`, `Message.file`, ...) instead of a single
class discriminated by a `MessageType` enum. The biggest behavioral change:
a message no longer embeds a full `author` object, only `authorId` (a
`String`). Resolve the `User` for display via `Chat.resolveUser`, not from
the message itself.

There are no more `PartialText`/`PartialImage`/`PartialFile`/`PartialCustom`
helper types. Build a full `Message` yourself (with your own id — use
`const Uuid().v7()`, not `.v4()`, see [Room/message ids are now uuid](#roommessage-ids-are-now-uuid)
above) and pass it to `SupabaseChatController.sendMessage`:

```dart
// v1
final message = types.PartialText(text: text);
await SupabaseChatCore.instance.sendMessage(message, room.id);

// v2
final message = core.Message.text(
  id: const Uuid().v7(),
  authorId: SupabaseChatCore.instance.loggedSupabaseUser!.id,
  text: text,
);
await _chatController.sendMessage(message);
```

### `SupabaseChatController` now implements `ChatController`

In v1 it exposed `Stream<List<types.Message>> get messages`. In v2 it
directly implements `flutter_chat_core`'s `ChatController` (backed
internally by an `InMemoryChatController` that Supabase Realtime keeps in
sync via `insertMessage`/`updateMessage`/`removeMessage` instead of
refetch-and-replace), so you pass it straight to `Chat.chatController` — no
`StreamBuilder` needed around messages:

```dart
// v1
StreamBuilder<List<types.Message>>(
  stream: _chatController.messages,
  builder: (context, snapshot) => Chat(
    messages: snapshot.data ?? [],
    user: SupabaseChatCore.instance.loggedUser!,
    ...
  ),
)

// v2
Chat(
  currentUserId: SupabaseChatCore.instance.loggedSupabaseUser!.id,
  resolveUser: (id) async => ...,        // see example/lib/src/pages/room.dart
  chatController: _chatController,
  onMessageSend: (text) => ...,
  builders: core.Builders(
    textMessageBuilder: (context, message, index, {required isSentByMe, groupStatus}) =>
        FlyerChatTextMessage(message: message, index: index),
    // one builder per message type you use — see below.
  ),
)
```

`typingUsers`, `onTyping()`, `endTyping()`, `loadPreviousMessages()` and
`deleteMessage()` are unchanged in spirit (`deleteMessage` now only takes
the message id — the controller already knows its room). New:
`sendMessage(message)` — send through the controller instead of
`SupabaseChatCore.instance.sendMessage(message, roomId)` to get optimistic
local insertion, see [Room/message ids are now uuid](#roommessage-ids-are-now-uuid).

### Message type widgets are separate packages now

`flutter_chat_ui` v2 ships no built-in renderer for images/files/etc. (only
plain text has a minimal fallback). Add the `flyer_chat_*_message` package
for each message type you use and wire it through `Builders`:

```yaml
dependencies:
  flyer_chat_text_message: ^2.6.0
  flyer_chat_image_message: ^2.3.0
  flyer_chat_file_message: ^2.4.0
```

See `example/lib/src/pages/room.dart` for a complete `Builders` setup,
including authenticated image loading via
`FlyerChatImageMessage(headers: SupabaseChatCore.instance.httpSupabaseHeaders)`.

### Dropped / changed features

- **`onMessageVisibilityChanged`** (used in v1 to mark a message as "seen"
  when it scrolled into view) has no equivalent on v2's `Chat` widget. If
  you need read receipts, call
  `SupabaseChatCore.instance.updateMessage(message.copyWith(status: core.MessageStatus.seen), roomId)`
  from your own visibility tracking (e.g. a `NotificationListener` around
  `Builders.chatAnimatedListBuilder`, or per-message `VisibilityDetector`).
- **Automatic link preview fetching** (`onPreviewDataFetched` in v1) has no
  direct v2 equivalent at the `Chat` widget level. `linkPreviewData` is
  still read/written by this package if you populate it yourself.

## Checklist

1. Run `example/utils/sql/01_database_schema.sql` then `05_database_view.sql`
   against your database, during a maintenance window.
2. Update `pubspec.yaml`: replace `flutter_chat_types` + `flutter_chat_ui`
   1.x with `flutter_chat_core` + `flutter_chat_ui` 2.x, add the
   `flyer_chat_*_message` packages you need, bump
   `flutter_supabase_chat_core` to `^2.0.0`.
3. Replace `types.Room`/`types.User` with `ChatRoom`/`ChatUser` everywhere.
4. Replace `Partial*` message construction with `Message.text`/`.image`/...,
   generating ids with `const Uuid().v7()` (not `.v4()`), and send through
   `_chatController.sendMessage(message)` instead of
   `SupabaseChatCore.instance.sendMessage(message, roomId)` directly.
5. Wire `Chat.currentUserId` / `Chat.resolveUser` / `Chat.chatController`
   / `Chat.builders` instead of the old `messages`/`user`/`showUserNames`
   props.
6. Re-implement "seen" tracking and link previews if you relied on them.
7. If your own code parses a room/message id as an int (like the old
   `SupabaseChatController._messagesQuery()` used to), drop that — ids are
   uuid strings now.
