import 'package:meta/meta.dart';

/// Class that represents the chat config. Can be used for setting custom names
/// for rooms and users collections. Call [SupabaseChatCore.instance.setConfig]
/// before doing anything else with [SupabaseChatCore.instance] if you want to
/// change the default collection names. When using custom names don't forget
/// to update your security rules and indexes.
@immutable
class SupabaseChatCoreConfig {
  const SupabaseChatCoreConfig(
    this.schema,
    this.roomsTableName,
    this.roomsViewName,
    this.messagesTableName,
    this.usersTableName,
    this.realtimeOnlineUserPrefixChannel,
    this.realtimeChatTypingUserPrefixChannel,
    this.chatAssetsBucket,
  );

  /// Property to set database schema name.
  final String schema;

  /// Property to set rooms table name.
  final String roomsTableName;

  /// Property to set rooms table view name.
  final String roomsViewName;

  /// Property to set messages table name.
  final String messagesTableName;

  /// Property to set users table name.
  final String usersTableName;

  /// Property to set online users realtime channel.
  final String realtimeOnlineUserPrefixChannel;

  /// Property to set users typing in room realtime channel.
  final String realtimeChatTypingUserPrefixChannel;

  /// Property to set chat assets bucket.
  final String chatAssetsBucket;
}
