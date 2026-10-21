## [2.0.0-rc.1] - 2026-10-21
#### [@rickypid](https://github.com/rickypid)

Release candidate of 2.0.0: the API and the database schema are complete, feedback welcome before the stable release.

⚠️⚠️ **Breaking change: Dart API and database schema, see [MIGRATION.md](MIGRATION.md)** ⚠️⚠️

Moves the package to `flutter_chat_core`/`flutter_chat_ui` 2.x and redesigns
the database. The same SQL scripts create a fresh database or migrate a 1.x
one (maintenance window required).

### Breaking changes

* `ChatRoom`, `ChatUser` and `flutter_chat_core`'s `Message` replace the
  `flutter_chat_types` models; dates are `DateTime`, ids are uuid strings.
* `SupabaseChatController` implements `flutter_chat_core`'s `ChatController`;
  `roomsUpdates()`/`updateRoomList` become `roomsChanges()`/`applyRoomChange`.
* `SupabaseChatCoreConfig` takes named parameters;
  `realtimeChatTypingUserPrefixChannel` becomes `realtimeRoomChannelPrefix`.
* Members are managed with `addMembers`/`removeMember`/`leaveRoom`/
  `setMemberRole` instead of `updateRoom`; `fetchUser` and
  `processRoomRow(s)` are removed.
* Errors are thrown as `SupabaseChatCoreException` subtypes.
* Database: uuid ids, `timestamptz` dates, `chats.room_members`, messages
  partitioned by week (`pg_partman` + `pg_cron`), rooms created through the
  `chats.create_room` RPC, message changes over private Realtime Broadcast
  channels (self-hosted Realtime >= v2.33).

### Added

* `SupabaseChatRoomsController`: paginated, searchable rooms list kept in
  sync over Realtime, with unread counters.
* Telegram-like features: read receipts and unread counts, replies,
  reactions, editing, pinned messages, message search, pinned and muted
  rooms, group roles, optimistic sending with retry.
* Scoping hooks on `SupabaseChatCoreConfig` to keep the chats of different
  workspaces apart.
* Injectable client (`SupabaseChatCore(client:, config:)`) and `dispose()`.
* `cleanup-media` Edge Function to delete the files of deleted messages.
* `migrate_storage_uuids.sh`/`.ps1`: moves the 1.x attachments to the new
  room folders.
* Redesigned Telegram-like example app, with voice messages on every
  platform.

### Fixed

* #38: the typing indicator hit the Realtime Presence rate limit; it now uses
  Broadcast.
* Web: the online status observer never removed its focus/blur listeners.
* Realtime channels leaked by the online status helpers.

### Security

* Stricter RLS: no self-granted membership, messages sent only as yourself,
  edits by the author, group management by admins only.
* Private room channels authorized by policies on `realtime.messages`.
* Policies limited to `authenticated`, internal tables and trigger functions
  closed to clients (clean Supabase advisors).

### Dependencies

* `flutter_chat_types` replaced by `flutter_chat_core: ^2.9.0`.
* `supabase_flutter: ^2.17.2`; Dart `>=3.8.0`, Flutter `>=3.32.0`.
* The example pins `flutter_chat_ui: '>=2.11.1 <2.12.0'` (2.12.0 crashes
  inside a standard `Scaffold`).

## [1.6.2] - 2026-03-31
#### [@rickypid](https://github.com/rickypid)

### Fixed

* Update Docusaurus dependencies to 3.9.2.

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
