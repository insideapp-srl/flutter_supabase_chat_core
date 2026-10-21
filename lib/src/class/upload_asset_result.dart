import 'package:meta/meta.dart';

/// Result of uploading a file through `SupabaseChatCore.uploadAsset` or
/// `SupabaseChatCore.uploadUserAvatar`.
@immutable
class UploadAssetResult {
  /// Creates an upload result.
  const UploadAssetResult({
    required this.url,
    required this.mimeType,
    this.path,
  });

  /// Authenticated URL of the uploaded file (load it with
  /// `SupabaseChatCore.httpSupabaseHeaders`).
  final String url;

  /// MIME type detected from the file name and content, if any.
  final String? mimeType;

  /// Object path inside its bucket.
  final String? path;
}
