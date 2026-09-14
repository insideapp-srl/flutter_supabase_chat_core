## [2.0.0] - 2026-08-25
#### [@rickypid](https://github.com/rickypid)

⚠️⚠️ **Breaking change, see [MIGRATION.md](MIGRATION.md)** ⚠️⚠️

Ports the package from `flutter_chat_types`/`flutter_chat_ui` 1.x to
`flutter_chat_core`/`flutter_chat_ui` 2.x (Flyer Chat's rewritten
architecture), including a database schema migration to align
`chats.messages` column names with the v2 model and partition it for
scalability — see [MIGRATION.md](MIGRATION.md), a maintenance window is
required.

### Added

* `example/`: audio message support — recording (`record` package, mic
  permission wired for Android/iOS/macOS) via a new "Audio" option in the
  attachment sheet, and playback via a custom `AudioMessageBubble` widget
  (downloads the authenticated audio file, then plays it locally with
  `audioplayers`). No library changes needed: `flutter_chat_core`'s
  `Message.audio` and `chats.messages`' `duration`/`waveform` columns
  already supported it — the official `flyer_chat_audio_message` widget
  package is currently an empty placeholder, hence the custom bubble.
* `ChatRoom`, `ChatRoomType`, `ChatRoomRole` and `ChatUser` classes,
  replacing `types.Room`/`types.RoomType`/`types.Role`/`types.User`, which
  no longer exist upstream.
* `example/utils/sql/01_database_schema.sql`: now a single, idempotent,
  self-detecting script — bootstraps a fresh v2 database or migrates an
  existing v1 (`flutter_chat_types`) one in place from the same file
  (renames `chats.messages` columns to their v2 names — `uri` → `source`,
  `waveForm` → `waveform`, `previewData` → `linkPreviewData` — and adds
  `replyToMessageId`, `reactions`, `pinned`; column rename/add only, no data
  touched). Re-running it on an already up-to-date v2 database is a no-op.
* `chats.messages` partitioning: converted to a native `PARTITION BY RANGE
  ("createdAt")` table (epoch milliseconds), managed by `pg_partman` with
  weekly partitions, no automatic retention (history kept forever) and
  hourly maintenance scheduled via `pg_cron`. Requires the `pg_partman` and
  `pg_cron` extensions (both ship in Supabase's self-hosted Postgres image).
  Primary key is now composite (`id`, `"createdAt"`) as required by native
  partitioning. Converting an existing table keeps the old one as
  `chats.messages_pre_partition` instead of dropping it.
* `chats.ensure_messages_partitions_rls()`: enabling RLS on `chats.messages`
  does **not** retroactively cover partitions pg_partman creates afterwards
  (unlike indexes/triggers, which Postgres does propagate) — confirmed by
  Supabase's own linter flagging every partition as "RLS disabled". This
  function enables it on any partition missing it; called right after
  `partman.create_parent(...)` and from the hourly `pg_cron` maintenance job
  going forward.
* `MIGRATION.md`: full v1 to v2 migration guide, including the message
  partitioning notes above.
* `chats.rooms.id`/`chats.messages.id`/`chats.messages."roomId"`: converted
  from `bigint` identity to `uuid` (default `chats.uuid_generate_v7()`, a
  time-ordered UUID — regular random UUIDs would fragment
  `chats.messages`'s partitioned indexes on every insert). `chats.users.id`
  is untouched. Converting an existing database renames the old
  `chats.rooms`/`chats.messages` tables to timestamped `..._backup_*`
  tables (kept, not dropped) and remaps `"roomId"` via
  `chats.room_id_migration_map`, a durable (not PostgREST-exposed) mapping
  table left behind for `example/utils/migrate_storage_uuids.sh`/`.ps1`
  (new) to move `chats_assets` storage objects from their old numeric room
  folder to the new uuid one — SQL alone can't rename storage objects, and
  leaving them under the old path makes them permanently inaccessible once
  the storage RLS policy starts casting that path segment to `uuid`. Enables
  optimistic message sending: `SupabaseChatController.sendMessage(message)`
  (build `message` with `const Uuid().v7()` as its id) inserts locally right
  away and reconciles with Realtime's echo of the same id instead of
  waiting for it.
* `example/utils/supabase_prepare.sh`/`.ps1`: automates the manual "Create a
  Supabase project" steps from the README — after logging in (`supabase
  login`, launched for you if needed), lets you pick to create a new project
  or reuse an existing one, both via arrow-key (↑/↓ + Enter) list pickers for
  organization/region/project instead of typing IDs or numbers. Generates a
  database password for a new project (Supabase never shows it again after
  creation) or prompts for it when reusing an existing one (only needed to
  run `prepare.sh`/`.ps1` right away). Writes
  `example/lib/supabase_options_for_test.dart` and `example/lib/main_test.dart`
  (both gitignored — `main.dart`/`supabase_options.dart` stay untouched
  placeholders). All collected references (ref, URL, anon/service_role keys,
  DB host/port/user/password) are written to
  `example/utils/project-secrets.local.json` (gitignored — contains secrets,
  never commit it). The manual steps are kept in the README/docs as a
  fallback.
* `doc/`: the whole Docusaurus site content rewritten for the 2.x API
  (`ChatUser`/`ChatRoom`, `SupabaseChatController`, paginated `users()`/
  `rooms()`, error handling, ...) and for the pg_partman-partitioned schema;
  favicon, apple-touch-icon and navbar logo (light/dark variants) refreshed
  from Flyer Chat's current branding — the previous ones were years stale
  and some had gone 404, same issue as the README images above.
* Error handling: `SupabaseChatCoreException` (`SupabaseChatCoreAuthException`,
  `SupabaseChatCoreRequestException`, `SupabaseChatCoreStorageException`) wrap
  every error `SupabaseChatCore`'s and `SupabaseChatController`'s public
  methods can throw (Postgrest/Auth/Storage errors, connectivity, ...), so
  callers can catch one type instead of every possible Supabase exception.
  `SupabaseChatController` also gained an optional `onError` constructor
  callback, since its background operations (initial load, realtime
  insert/update/delete) aren't awaited by any caller and previously failed
  silently.

### Changed

* `SupabaseChatController` now implements `flutter_chat_core`'s
  `ChatController` directly (backed by an `InMemoryChatController` kept in
  sync with Supabase Realtime), instead of exposing a
  `Stream<List<types.Message>>`.
* `SupabaseChatCore.sendMessage`/`updateMessage` now take a
  `flutter_chat_core` `Message` (built via `Message.text`/`.image`/...)
  instead of the removed `types.Partial*` types.
* `example/` ported to `flutter_chat_ui` 2.x (`Chat.chatController`,
  `Chat.resolveUser`, `Chat.builders` with `flyer_chat_text_message`,
  `flyer_chat_image_message`, `flyer_chat_file_message`).
* `chats.messages_l` view no longer joins `chats.users`/`chats.rooms_l` to
  embed `author`/`room` (v2 messages only carry `authorId`, not an embedded
  author) — it's now a straight passthrough of `chats.messages` under RLS.
* `createRoom`/`createGroupRoom` now throw `SupabaseChatCoreAuthException`
  instead of `Future.error('User does not exist')` when there's no logged-in
  user. `sendMessage`/`updateRoom` now throw the same instead of silently
  no-op-ing — previously a message send or room update with no logged-in
  user (e.g. a stale session) failed with no signal to the caller at all.

### Fixed

* `README.md`'s Flyer Chat logo and hero image now point at local copies
  (`doc/static/img/flyer-chat-logo-dark.svg`, `doc/static/img/flyer-chat-hero.jpg`)
  instead of hotlinking `flyer.chat`/`user-images.githubusercontent.com` — the
  logo URL had gone stale (flyer.chat moved the asset and the old path 404s).

### Dependencies

* Replaced `flutter_chat_types: ^3.6.2` with `flutter_chat_core: ^2.9.0`.
* Raised minimum SDKs to `Dart >=3.8.0` / `Flutter >=3.32.0` (required by
  `flutter_chat_core`).
* `doc/` (the Docusaurus site): bumped `@docusaurus/*` packages from `3.6.3`
  to `3.10.2` to clear known vulnerabilities in their dependency tree (`npm
  audit`: 59 advisories, incl. 2 critical/18 high, down to 26, all
  moderate/high and all in upstream Docusaurus 3.x build tooling with no fix
  published yet — dev-time only, not shipped to site visitors; clearing them
  fully needs Docusaurus 4).
* Upgraded all direct dependencies (both this package and `example/`) to
  their latest versions allowed by existing constraints —
  `flutter_chat_core: 2.9.1`, `flyer_chat_*` patch bumps, `mime: 2.1.0`,
  `dio`/`file_picker`/etc. `example/`'s `flutter_chat_ui` is pinned to
  `>=2.11.1 <2.12.0`: 2.12.0 (released the same day) swapped `Composer`'s
  `TextField` to an experimental `material_ui` package with its own
  `Material` widget, which a standard `Scaffold` doesn't satisfy — crashes
  with "No Material widget found." on send. A handful of transitive
  packages (`meta`, `objective_c`, `vector_math`, ...) remain behind newer
  releases because they're pinned by the Flutter SDK itself, not by this
  package's constraints.

## [1.6.1] - 2026-03-09
#### [@rickypid](https://github.com/rickypid)

### Fixed

* Make `_focusListener` and `_blurListener` nullable in `WebWidgetsBinding`.

## [1.6.0] - 2025-06-17
#### [@rickypid](https://github.com/rickypid)

ℹ️ ℹ️ **Recommended scheme migration** ℹ️ ℹ️

### Fixed

* Fixed #29 update messages list after delete message
* Fixed update room last message trigger

### Dependencies

* Upgraded `supabase_flutter` to `^2.9.1`
* Upgraded `meta` to `^1.16.0`
* Added `web` `^1.1.1`
 
## [1.5.0] - 2025-02-06
#### [@rickypid](https://github.com/rickypid)

### Dependencies

* Upgrade supabase_flutter: ^2.8.3

## [1.4.3] - 2024-12-26
#### [@rickypid](https://github.com/rickypid)
#### [@lazy-geek](https://github.com/lazy-geek)

ℹ️ ℹ️ **Recommended scheme migration** ℹ️ ℹ️

Improvement documentations.

### Fixed

* Fixed #25 Update chats.update_last_messages trigger to make sure it is only called for actual last message in case of update
* Fixed #27 Error in room or message deletion query, a `limit(1)` was incorrectly applied

## [1.4.2] - 2024-11-30
#### [@rickypid](https://github.com/rickypid)

### Dependencies

* Upgrade mine: '>=1.0.2 <3.0.0'

## [1.4.1] - 2024-11-21
#### [@rickypid](https://github.com/rickypid)
#### [@Parfyonator](https://github.com/Parfyonator)

### Fixed

* Fixed #20 Chat creator role is null instead of admin

## [1.4.0] - 2024-11-21
#### [@rickypid](https://github.com/rickypid)

⚠️⚠️ **Need schema migration** ⚠️⚠️

### Improvements

* Now when we get the rooms the `rooms_l` view is used so that we can get all the information without having to do multiple queries

### Fixed

* Fixed #20 Chat creator role is null instead of admin
* Fixed online user status realtime subscription

## [1.3.2] - 2024-11-13
#### [@rickypid](https://github.com/rickypid)

Improve documentations

### Fixed

* Fixed schema `chats` permission after view creation

## [1.3.1] - 2024-11-12
#### [@rickypid](https://github.com/rickypid)

### Fixed

* Fixed `updateRoomList` sorting 
 
## [1.3.0] - 2024-11-04
#### [@rickypid](https://github.com/rickypid)

⚠️⚠️ **Some Breaking Changes** ⚠️⚠️

### New features

* Added Rooms list pagination and searchable

### Fixed

* Security fix on RLS helper functions

## [1.2.0] - 2024-10-31
#### [@rickypid](https://github.com/rickypid)

⚠️⚠️ **Some Breaking Changes** ⚠️⚠️
 
### New features

* Added Users list pagination and searchable
* Added Users typing status

### Fixed

* Fix database index e security fix on function

## [1.1.0] - 2024-08-30
#### [@danbeech](https://github.com/danbeech)
#### [@rickypid](https://github.com/rickypid)

### Fixed

* Fixed update room call
* Fixed Dart SDK version for Flutter 3.22.x (#9)
* Updated dependencies

## [1.0.0] - 2024-06-19
#### [@rickypid](https://github.com/rickypid)

### Fixed

* Fixed schema migration (#3)
* Fixed example theme variables, now support Flutter > 3.22.x

## [0.10.0] - 2024-04-04
#### [@rickypid](https://github.com/rickypid)

### Features

* Added user online status support
* Added room messages pagination, now it's possible load messages on chat scrolling
* Added `SupabaseChatController`

### Widgets

* Added `UserOnlineStateObserver` widget
* Added `UserOnlineStatusWidget` widget

### Dependencies

* Removed `dio` dependency
* Upgraded `supabase_flutter` to `^2.4.0`

## [0.9.0] - 2024-03-11
#### [@rickypid](https://github.com/rickypid)

* Improved documentation
* Fixed RSL on chats schema
* Add files download support
* Test on Android device
* Renamed `SupabseChatCore` to `SupabaseChatCore` 😅 (typo)
* Added logic to change status in read messages
* Dependencies updated

## [0.0.2] - 2024-02-12
#### [@rickypid](https://github.com/rickypid)

* Improved documentation and fixed GitHub Pages CI

## [0.0.1] - 2024-02-09
#### [@rickypid](https://github.com/rickypid)

* Initial release
