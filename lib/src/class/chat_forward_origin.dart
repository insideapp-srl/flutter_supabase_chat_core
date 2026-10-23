import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:meta/meta.dart';

import '../util.dart';

/// Where a forwarded message comes from, stored in its metadata under
/// [metadataKey].
///
/// Written by the database, never by clients: `SupabaseChatCore.forwardMessages`
/// only names the forwarded message ([claim]), and the
/// `chats.attest_forward_origin` trigger replaces that with the source's
/// author, author name and date (or the source's own origin, when it is
/// itself a forward), after checking the forwarder can read it. Any other
/// value is rejected, so an origin can't be made up.
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

  /// The metadata value a client stores under [metadataKey] when forwarding
  /// message [sourceMessageId] of room [sourceRoomId]: the database replaces
  /// it with the attested origin.
  static Map<String, dynamic> claim({
    required String sourceRoomId,
    required String sourceMessageId,
  }) => {'sourceRoomId': sourceRoomId, 'sourceMessageId': sourceMessageId};

  /// The metadata value of this origin, as stored by the database.
  Map<String, dynamic> toJson() => {
    'authorId': authorId,
    if (authorName != null) 'authorName': authorName,
    if (createdAt != null) 'createdAt': formatChatDate(createdAt),
  };
}
