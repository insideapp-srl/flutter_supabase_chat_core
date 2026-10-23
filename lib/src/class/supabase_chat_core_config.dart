import 'package:meta/meta.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_room.dart';

/// Signature of a hook that narrows a Supabase select query, e.g. to scope
/// rooms or users to an organization, workspace or any other partition of
/// your data. Return the (possibly filtered) [query].
typedef ChatQueryFilter =
    PostgrestFilterBuilder<PostgrestList> Function(
      PostgrestFilterBuilder<PostgrestList> query,
    );

/// Signature of a hook that decides whether a [ChatRoom] received over
/// Realtime belongs to the current scope (see
/// [SupabaseChatCoreConfig.roomFilter]).
typedef ChatRoomPredicate = bool Function(ChatRoom room);

/// Signature of a hook returning metadata merged into every new room (see
/// [SupabaseChatCoreConfig.defaultRoomMetadata]).
typedef ChatMetadataProvider = Map<String, dynamic> Function();

/// Names of the database objects, Realtime channels and storage buckets the
/// package works with, plus optional hooks to scope the data it reads.
///
/// Call `SupabaseChatCore.instance.setConfig` before doing anything else with
/// `SupabaseChatCore.instance` if you need to change any of the defaults.
/// When using custom names don't forget to update the SQL scripts (RLS
/// policies, views, triggers) accordingly.
///
/// ## Scoping hooks
///
/// [defaultRoomMetadata], [roomsQueryFilter], [usersQueryFilter] and
/// [roomFilter] let a multi-tenant/multi-workspace app keep each scope's
/// chats separate without forking the package:
///
/// ```dart
/// SupabaseChatCore.instance.setConfig(
///   const SupabaseChatCoreConfig().copyWith(
///     defaultRoomMetadata: () => {'workspaceId': currentWorkspaceId},
///     roomsQueryFilter: (q) => q.eq('metadata->>workspaceId', currentWorkspaceId),
///     roomFilter: (room) => room.metadata?['workspaceId'] == currentWorkspaceId,
///   ),
/// );
/// ```
///
/// Hooks are evaluated on every call, so they can read state that changes at
/// runtime. They only narrow what the client asks for: enforce the same rule
/// server side (RLS) if it is a security boundary.
@immutable
class SupabaseChatCoreConfig {
  /// Creates a config. Every argument has a default matching the SQL scripts
  /// shipped in `example/utils/sql`.
  const SupabaseChatCoreConfig({
    this.schema = 'chats',
    this.roomsTableName = 'rooms',
    this.roomsViewName = 'rooms_l',
    this.roomMembersTableName = 'room_members',
    this.messagesTableName = 'messages',
    this.messagesViewName = 'messages_l',
    this.usersTableName = 'users',
    String? usersViewName,
    this.realtimeOnlineUserPrefixChannel = 'online-user-',
    this.realtimeRoomChannelPrefix = 'chats:room:',
    this.realtimeUserChannelPrefix = 'chats:user:',
    this.chatAssetsBucket = 'chats_assets',
    this.userAvatarsBucket = 'chats_user_avatar',
    this.defaultRoomMetadata,
    this.roomsQueryFilter,
    this.usersQueryFilter,
    this.roomFilter,
  }) : _usersViewName = usersViewName;

  /// Database schema holding every chat table, view and function.
  final String schema;

  /// Rooms table name (written to).
  final String roomsTableName;

  /// Rooms view name (read from): rooms with their members embedded.
  final String roomsViewName;

  /// Room membership table name (`roomId`, `userId`, `role`, `lastReadAt`).
  final String roomMembersTableName;

  /// Messages table name (written to, and listened to over Realtime).
  final String messagesTableName;

  /// Messages view name (read from).
  final String messagesViewName;

  /// Users table name (written to by `updateUser`).
  final String usersTableName;

  /// Users table or view name read by `users`/`user`. Defaults to
  /// [usersTableName]; point it at a view to expose a narrower or
  /// differently-sourced list of users (e.g. only users sharing a workspace
  /// with the caller).
  String get usersViewName => _usersViewName ?? usersTableName;
  final String? _usersViewName;

  /// Prefix of the private Presence channel used for a user's online status
  /// (`<prefix><uid>`). Any signed-in user may watch it, only `<uid>` may
  /// publish on it (RLS policies on `realtime.messages`, which match the
  /// default prefix).
  final String realtimeOnlineUserPrefixChannel;

  /// Prefix of a room's private Realtime Broadcast channels: `<prefix><roomId>`
  /// carries its message changes (sent by the database only) and
  /// `<prefix><roomId>:typing` its typing indicator (sent by members). Must
  /// match the topics used by the `chats.broadcast_message_change` trigger and
  /// the `realtime.messages` RLS policies in the SQL scripts.
  final String realtimeRoomChannelPrefix;

  /// Prefix of a user's private Realtime Broadcast channel
  /// (`<prefix><uid>`), on which the database announces changes to the
  /// user's rooms and memberships. Must match the topic used by the
  /// `chats.send_room_change` trigger function and the `realtime.messages`
  /// RLS policies in the SQL scripts.
  final String realtimeUserChannelPrefix;

  /// Storage bucket for message attachments (`<roomId>/<file>`).
  final String chatAssetsBucket;

  /// Storage bucket for user avatars (`<uid>/<file>`).
  final String userAvatarsBucket;

  /// Metadata merged into every room created by `createRoom` and
  /// `createGroupRoom`. Explicit `metadata` passed to those methods wins on
  /// conflicting keys. Also used to tell direct rooms apart: an existing
  /// direct room is only reused when its metadata contains these entries.
  final ChatMetadataProvider? defaultRoomMetadata;

  /// Applied to every rooms query (`rooms`, Realtime refetches).
  final ChatQueryFilter? roomsQueryFilter;

  /// Applied to every users query (`users`).
  final ChatQueryFilter? usersQueryFilter;

  /// Applied to every room received over Realtime: rooms for which it
  /// returns `false` are ignored. Keep it consistent with [roomsQueryFilter].
  final ChatRoomPredicate? roomFilter;

  /// Returns a copy with the given fields replaced.
  SupabaseChatCoreConfig copyWith({
    String? schema,
    String? roomsTableName,
    String? roomsViewName,
    String? roomMembersTableName,
    String? messagesTableName,
    String? messagesViewName,
    String? usersTableName,
    String? usersViewName,
    String? realtimeOnlineUserPrefixChannel,
    String? realtimeRoomChannelPrefix,
    String? realtimeUserChannelPrefix,
    String? chatAssetsBucket,
    String? userAvatarsBucket,
    ChatMetadataProvider? defaultRoomMetadata,
    ChatQueryFilter? roomsQueryFilter,
    ChatQueryFilter? usersQueryFilter,
    ChatRoomPredicate? roomFilter,
  }) => SupabaseChatCoreConfig(
    schema: schema ?? this.schema,
    roomsTableName: roomsTableName ?? this.roomsTableName,
    roomsViewName: roomsViewName ?? this.roomsViewName,
    roomMembersTableName: roomMembersTableName ?? this.roomMembersTableName,
    messagesTableName: messagesTableName ?? this.messagesTableName,
    messagesViewName: messagesViewName ?? this.messagesViewName,
    usersTableName: usersTableName ?? this.usersTableName,
    usersViewName: usersViewName ?? _usersViewName,
    realtimeOnlineUserPrefixChannel:
        realtimeOnlineUserPrefixChannel ?? this.realtimeOnlineUserPrefixChannel,
    realtimeRoomChannelPrefix:
        realtimeRoomChannelPrefix ?? this.realtimeRoomChannelPrefix,
    realtimeUserChannelPrefix:
        realtimeUserChannelPrefix ?? this.realtimeUserChannelPrefix,
    chatAssetsBucket: chatAssetsBucket ?? this.chatAssetsBucket,
    userAvatarsBucket: userAvatarsBucket ?? this.userAvatarsBucket,
    defaultRoomMetadata: defaultRoomMetadata ?? this.defaultRoomMetadata,
    roomsQueryFilter: roomsQueryFilter ?? this.roomsQueryFilter,
    usersQueryFilter: usersQueryFilter ?? this.usersQueryFilter,
    roomFilter: roomFilter ?? this.roomFilter,
  );
}
