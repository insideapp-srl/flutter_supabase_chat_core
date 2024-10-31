import 'package:meta/meta.dart';

/// Class that represents the chat config. Can be used for setting custom names
/// for rooms and users collections. Call [FirebaseChatCore.instance.setConfig]
/// before doing anything else with [FirebaseChatCore.instance] if you want to
/// change the default collection names. When using custom names don't forget
/// to update your security rules and indexes.
@immutable
class SupabaseChatCoreConfig {
  const SupabaseChatCoreConfig(
    this.schema,
    this.roomsTableName,
    this.messagesTableName,
    this.usersTableName,
    this.realtimeOnlineUserPrefixChannel,
    this.realtimeChatTypingUserPrefixChannel,
  );

  /// Property to set database schema name.
  final String schema;

  /// Property to set rooms table name.
  final String roomsTableName;

  /// Property to set messages table name.
  final String messagesTableName;

  /// Property to set users table name.
  final String usersTableName;

  /// Property to set online users realtime channel.
  final String realtimeOnlineUserPrefixChannel;

  /// Property to set users typing in room realtime channel.
  final String realtimeChatTypingUserPrefixChannel;
}
