import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseChatDate', () {
    test('parses timestamptz strings to UTC', () {
      final date = parseChatDate('2026-10-20T16:16:48.600641+02:00');
      expect(date, DateTime.utc(2026, 10, 20, 14, 16, 48, 600, 641));
      expect(date!.isUtc, isTrue);
    });

    test('parses epoch milliseconds', () {
      expect(parseChatDate(0), DateTime.utc(1970));
      expect(parseChatDate(1000.0), DateTime.utc(1970, 1, 1, 0, 0, 1));
    });

    test('returns null for null or garbage', () {
      expect(parseChatDate(null), isNull);
      expect(parseChatDate('not a date'), isNull);
      expect(parseChatDate(const <String>[]), isNull);
    });

    test('formatChatDate round-trips', () {
      final date = DateTime.utc(2026, 1, 2, 3, 4, 5);
      expect(parseChatDate(formatChatDate(date)), date);
      expect(formatChatDate(null), isNull);
    });
  });

  group('messageFromRow', () {
    final base = {
      'id': '0199f0aa-0000-7000-8000-000000000001',
      'roomId': '0199f0aa-0000-7000-8000-0000000000ff',
      'authorId': 'a0000000-0000-0000-0000-000000000001',
      'createdAt': '2026-10-20T10:00:00+00:00',
      'updatedAt': null,
      'metadata': null,
      'status': 'sent',
    };

    test('maps a text row, dropping roomId and nulls', () {
      final message = messageFromRow({...base, 'type': 'text', 'text': 'Hi'});
      expect(message, isA<core.TextMessage>());
      final text = message as core.TextMessage;
      expect(text.text, 'Hi');
      expect(text.id, base['id']);
      expect(text.authorId, base['authorId']);
      expect(text.createdAt, DateTime.utc(2026, 10, 20, 10));
      expect(text.status, core.MessageStatus.sent);
    });

    test('converts duration from milliseconds to seconds', () {
      final message = messageFromRow({
        ...base,
        'type': 'audio',
        'source': 'https://x/a.m4a',
        'duration': 12400,
        'size': 10,
      });
      expect(
        (message as core.AudioMessage).duration,
        const Duration(seconds: 12),
      );
    });

    test('normalizes reactions and legacy link previews', () {
      final message =
          messageFromRow({
                ...base,
                'type': 'text',
                'text': 'see https://flyer.chat',
                'reactions': {
                  '👍': ['u1', 'u2'],
                },
                'linkPreviewData': {
                  'link': 'https://flyer.chat',
                  'title': 'Flyer',
                  'image': {'url': 'https://flyer.chat/i.png'},
                },
              })
              as core.TextMessage;
      expect(message.reactions, {
        '👍': ['u1', 'u2'],
      });
      expect(message.linkPreviewData?.title, 'Flyer');
      expect(message.linkPreviewData?.image?.width, 0);
    });

    test('ignores an unknown status instead of failing', () {
      final message = messageFromRow({
        ...base,
        'type': 'text',
        'text': 'x',
        'status': 'teleported',
      });
      expect(message, isA<core.TextMessage>());
      expect(message.status, isNull);
    });

    test('falls back to unsupported for rows missing required fields', () {
      final message = messageFromRow({...base, 'type': 'image'});
      expect(message, isA<core.UnsupportedMessage>());
      expect(message.id, base['id']);
      expect(message.createdAt, DateTime.utc(2026, 10, 20, 10));
    });

    test('treats a missing type as unsupported', () {
      expect(messageFromRow({...base}), isA<core.UnsupportedMessage>());
    });

    test('reads rooms."lastMessages" snapshots (to_jsonb of a row)', () {
      final message = messageFromRow({
        ...base,
        'type': 'file',
        'source': 'https://x/f.pdf',
        'name': 'f.pdf',
        'size': 3,
        'mimeType': 'application/pdf',
        'height': null,
        'width': null,
        'waveform': null,
      });
      expect((message as core.FileMessage).name, 'f.pdf');
    });
  });

  group('messageToRow', () {
    test('keeps only table columns and converts duration to ms', () {
      final row = messageToRow(
        core.Message.audio(
          id: 'm1',
          authorId: 'u1',
          source: 'https://x/a.m4a',
          duration: const Duration(seconds: 3),
          size: 42,
          createdAt: DateTime.utc(2026),
        ),
      );
      expect(row['type'], 'audio');
      expect(row['duration'], 3000);
      expect(row['size'], 42);
      expect(row.containsKey('id'), isFalse);
      expect(row.containsKey('authorId'), isFalse);
      expect(row.containsKey('createdAt'), isFalse);
    });

    test('round-trips through messageFromRow', () {
      final original = core.Message.image(
        id: 'm2',
        authorId: 'u1',
        source: 'https://x/i.png',
        width: 640,
        height: 480,
        size: 1000,
        createdAt: DateTime.utc(2026, 5, 1),
        metadata: {'k': 'v'},
      );
      final row = messageToRow(original)
        ..['id'] = original.id
        ..['authorId'] = original.authorId
        ..['createdAt'] = formatChatDate(original.createdAt);
      expect(messageFromRow(row), original);
    });

    test('rejects client-only message types', () {
      expect(
        () => messageToRow(
          const core.Message.textStream(id: 's', authorId: 'u', streamId: 's'),
        ),
        throwsArgumentError,
      );
      expect(
        () => messageToRow(
          const core.Message.unsupported(id: 'x', authorId: 'u'),
        ),
        throwsArgumentError,
      );
    });
  });
}
