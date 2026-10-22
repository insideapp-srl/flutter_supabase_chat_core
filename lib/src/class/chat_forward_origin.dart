import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:meta/meta.dart';

import '../util.dart';

/// Where a forwarded message comes from, stored in its metadata under
/// [metadataKey] by `SupabaseChatCore.forwardMessages`.
///
/// The author's name is a snapshot taken when forwarding: the recipients may
/// not be able to read the original author's profile (they don't share a
/// room with them).
@immutable
class ChatForwardOrigin {
  /// Creates a forward origin.
  const ChatForwardOrigin({
    required this.authorId,
    this.authorName,
    this.createdAt,
  });

  /// Metadata key of the origin of a forwarded message.
  static const metadataKey = 'forwardedFrom';

  /// The origin of [message], or `null` when it wasn't forwarded.
  static ChatForwardOrigin? of(core.Message message) {
    final origin = message.metadata?[metadataKey];
    if (origin is! Map || origin['authorId'] == null) return null;
    return ChatForwardOrigin(
      authorId: origin['authorId'].toString(),
      authorName: origin['authorName'] as String?,
      createdAt: parseChatDate(origin['createdAt']),
    );
  }

  /// Id of the original message's author.
  final String authorId;

  /// Name of the original author when the message was forwarded, if known.
  final String? authorName;

  /// When the original message was sent, if known.
  final DateTime? createdAt;

  /// The metadata value of this origin.
  Map<String, dynamic> toJson() => {
    'authorId': authorId,
    if (authorName != null) 'authorName': authorName,
    if (createdAt != null) 'createdAt': formatChatDate(createdAt),
  };
}
