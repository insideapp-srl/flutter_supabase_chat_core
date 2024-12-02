## [1.4.3] - 2024-11-30
#### [@rickypid](https://github.com/rickypid)

Improvement documentations.

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
