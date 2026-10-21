import 'package:flutter_chat_core/flutter_chat_core.dart' as core;

/// Parses a date as returned by Supabase/PostgREST into a UTC [DateTime].
///
/// Accepts an ISO-8601 string (`timestamptz` columns), epoch milliseconds
/// (`int`, e.g. legacy rows or `flutter_chat_core` JSON) or a [DateTime].
/// Returns `null` for `null` or unparseable values.
DateTime? parseChatDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  return null;
}

/// Formats [value] the way `timestamptz` columns expect it (ISO-8601, UTC).
String? formatChatDate(DateTime? value) => value?.toUtc().toIso8601String();

const _messageDateKeys = {
  'createdAt',
  'updatedAt',
  'deletedAt',
  'failedAt',
  'sentAt',
  'deliveredAt',
  'seenAt',
  'editedAt',
};

/// Builds a `flutter_chat_core` [core.Message] out of a raw `messages` (or
/// `messages_l`) table row, a Realtime payload record or a
/// `rooms."lastMessages"` snapshot.
///
/// The `messages` table columns match `flutter_chat_core`'s v2 field names
/// directly (`source`, `waveform`, `linkPreviewData`, `replyToMessageId`,
/// ...), so this only needs to: stringify the uuid `id`/`authorId`, convert
/// `timestamptz` dates to the epoch milliseconds `flutter_chat_core`'s JSON
/// uses, convert `duration` from the DB's milliseconds to v2's seconds, and
/// normalize a legacy-shaped `linkPreviewData` (e.g. missing the image
/// width/height v2 requires).
///
/// Never throws: a row that doesn't match its declared type becomes a
/// [core.UnsupportedMessage], so one bad row can't break a whole list.
core.Message messageFromRow(Map<String, dynamic> row) {
  final id = row['id'].toString();
  final authorId = row['authorId'].toString();

  final json = <String, dynamic>{...row}
    ..['id'] = id
    ..['authorId'] = authorId
    ..['type'] = row['type'] ?? 'unsupported'
    ..remove('roomId');

  for (final key in _messageDateKeys) {
    if (!json.containsKey(key)) continue;
    final date = parseChatDate(json[key]);
    if (date == null) {
      json.remove(key);
    } else {
      json[key] = date.millisecondsSinceEpoch;
    }
  }

  // Drop nulls: flutter_chat_core's generated fromJson treats an explicit
  // null for a non-nullable field as a type error, but uses the default for
  // a missing one.
  json.removeWhere((key, value) => value == null);

  final durationMs = row['duration'];
  if (durationMs is num) {
    json['duration'] = (durationMs / 1000).round();
  }

  final status = json['status'];
  if (status is String &&
      !core.MessageStatus.values.any((value) => value.name == status)) {
    json.remove('status');
  }

  final reactions = json['reactions'];
  if (reactions is Map) {
    json['reactions'] = {
      for (final entry in reactions.entries)
        entry.key.toString(): [
          for (final userId in (entry.value as List? ?? const []))
            userId.toString(),
        ],
    };
  } else {
    json.remove('reactions');
  }

  final preview = row['linkPreviewData'];
  if (preview is! Map || preview['link'] == null) {
    json.remove('linkPreviewData');
  } else {
    final image = preview['image'];
    json['linkPreviewData'] = {
      'link': preview['link'],
      if (preview['title'] != null) 'title': preview['title'],
      if (preview['description'] != null) 'description': preview['description'],
      if (image is Map && image['url'] != null)
        'image': {
          'url': image['url'],
          'width': (image['width'] as num?)?.toDouble() ?? 0,
          'height': (image['height'] as num?)?.toDouble() ?? 0,
        },
    };
  }

  try {
    return core.Message.fromJson(json);
  } on Object {
    // Row didn't carry the fields required by its declared type (e.g. a
    // legacy row with unexpected nulls). Fall back to an unsupported
    // message instead of crashing the realtime/pagination stream.
    return core.Message.unsupported(
      id: id,
      authorId: authorId,
      createdAt: parseChatDate(row['createdAt']),
      metadata: (row['metadata'] as Map?)?.cast<String, dynamic>(),
    );
  }
}

/// Columns of the `messages` table that a [core.Message] can populate.
/// `id`, `authorId`, `roomId` and the dates are deliberately excluded:
/// callers set those explicitly (see `SupabaseChatCore.sendMessage`).
const _messageRowKeys = {
  'type',
  'status',
  'metadata',
  'reactions',
  'pinned',
  'replyToMessageId',
  'text',
  'source',
  'name',
  'mimeType',
  'size',
  'width',
  'height',
  'duration',
  'waveform',
  'linkPreviewData',
};

/// Builds a `messages` table row out of a `flutter_chat_core` [core.Message].
///
/// Throws an [ArgumentError] for message types that can't be persisted
/// ([core.TextStreamMessage], [core.UnsupportedMessage]).
Map<String, dynamic> messageToRow(core.Message message) {
  if (message is core.TextStreamMessage) {
    throw ArgumentError(
      'TextStreamMessage is a client-side only placeholder and cannot be '
      'persisted. Send a TextMessage once streaming is complete.',
    );
  }
  if (message is core.UnsupportedMessage) {
    throw ArgumentError('Cannot persist an UnsupportedMessage.');
  }

  final json = message.toJson();
  final row = <String, dynamic>{
    for (final key in _messageRowKeys)
      if (json.containsKey(key)) key: json[key],
  };

  final duration = row['duration'];
  if (duration is int) {
    row['duration'] = duration * 1000; // stored in milliseconds
  }

  return row;
}
