/// Base class for every exception thrown by [SupabaseChatCore] and
/// [SupabaseChatController]'s public API.
///
/// Wraps whatever the underlying Supabase client actually threw (a
/// `PostgrestException`, `AuthException`, `StorageException`, or any other
/// error) as [cause], so callers can catch this one type instead of having
/// to know every exception type the Supabase client can raise.
sealed class SupabaseChatCoreException implements Exception {
  const SupabaseChatCoreException(this.message, {this.cause, this.stackTrace});

  /// Describes which operation failed (e.g. `'sendMessage'`).
  final String message;

  /// The original error/exception this wraps, if any.
  final Object? cause;

  /// The stack trace captured at the point [cause] was thrown, if any.
  final StackTrace? stackTrace;

  @override
  String toString() => cause == null
      ? '$runtimeType: $message'
      : '$runtimeType: $message (cause: $cause)';
}

/// Thrown when an operation requires a logged-in Supabase user and there
/// isn't one.
final class SupabaseChatCoreAuthException extends SupabaseChatCoreException {
  const SupabaseChatCoreAuthException(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}

/// Thrown when a Supabase/Postgres request fails (RLS permission denied,
/// constraint violation, connectivity, ...).
final class SupabaseChatCoreRequestException extends SupabaseChatCoreException {
  const SupabaseChatCoreRequestException(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}

/// Thrown when uploading a chat asset (image, file, avatar) to Supabase
/// Storage fails.
final class SupabaseChatCoreStorageException extends SupabaseChatCoreException {
  const SupabaseChatCoreStorageException(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}
