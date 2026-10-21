/// Online status of a user, as tracked over Supabase Realtime Presence.
enum UserOnlineStatus {
  /// The user has the app in the foreground.
  online,

  /// The user has the app in the background, closed, or is logged out.
  offline,
}
