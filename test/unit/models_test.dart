import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

const _me = 'a0000000-0000-0000-0000-000000000001';
const _other = 'b0000000-0000-0000-0000-000000000002';

Map<String, dynamic> _roomRow({
  String type = 'direct',
  String? name,
  int unread = 0,
}) => {
  'id': 'r1',
  'type': type,
  'name': name,
  'imageUrl': null,
  'metadata': {'workspaceId': 'w1'},
  'createdAt': '2026-10-01T00:00:00+00:00',
  'updatedAt': '2026-10-02T00:00:00+00:00',
  'lastReadAt': null,
  'unreadCount': unread,
  'lastMessages': [
    {
      'id': 'm1',
      'authorId': _other,
      'roomId': 'r1',
      'type': 'text',
      'text': 'Last one',
      'createdAt': '2026-10-02T00:00:00+00:00',
    },
  ],
  'users': [
    {'id': _me, 'firstName': 'Alice', 'lastName': 'Liddell', 'role': 'admin'},
    {
      'id': _other,
      'firstName': 'Bob',
      'lastName': null,
      'imageUrl': 'https://x/bob.png',
      'role': null,
    },
  ],
};

void main() {
  group('ChatUser', () {
    test('fromJson reads timestamptz dates and unknown roles leniently', () {
      final user = ChatUser.fromJson({
        'id': _me,
        'firstName': 'Alice',
        'lastName': 'Liddell',
        'role': 'superuser',
        'createdAt': '2026-01-01T00:00:00Z',
        'lastSeen': 1767225600000,
      });
      expect(user.role, isNull);
      expect(user.createdAt, DateTime.utc(2026));
      expect(user.lastSeen, DateTime.utc(2026));
      expect(user.fullName, 'Alice Liddell');
      expect(user.initials, 'AL');
    });

    test('toJson/fromJson round-trip', () {
      final user = ChatUser(
        id: _me,
        firstName: 'A',
        role: ChatRoomRole.moderator,
        metadata: const {'k': 1},
        createdAt: DateTime.utc(2026, 2, 3),
      );
      final copy = ChatUser.fromJson(user.toJson());
      expect(copy.role, ChatRoomRole.moderator);
      expect(copy.metadata, {'k': 1});
      expect(copy.createdAt, user.createdAt);
    });

    test('toCoreUser carries name, avatar and role', () {
      final core = const ChatUser(
        id: _me,
        firstName: 'Alice',
        imageUrl: 'https://x/a.png',
        role: ChatRoomRole.admin,
      ).toCoreUser();
      expect(core.name, 'Alice');
      expect(core.imageSource, 'https://x/a.png');
      expect(core.metadata, {'role': 'admin'});
    });

    test('names fall back gracefully', () {
      const empty = ChatUser(id: _me);
      expect(empty.fullName, '');
      expect(empty.initials, '');
      expect(empty.toCoreUser().name, isNull);
    });
  });

  group('ChatRoom.fromJson', () {
    test('a direct room takes the other member name and avatar', () {
      final room = ChatRoom.fromJson(_roomRow(), currentUserId: _me);
      expect(room.type, ChatRoomType.direct);
      expect(room.name, 'Bob');
      expect(room.imageUrl, 'https://x/bob.png');
      expect(room.otherUser(_me)?.id, _other);
    });

    test('a group room keeps its own name and member roles', () {
      final room = ChatRoom.fromJson(
        _roomRow(type: 'group', name: 'Team', unread: 4),
        currentUserId: _me,
      );
      expect(room.name, 'Team');
      expect(room.roleOf(_me), ChatRoomRole.admin);
      expect(room.roleOf(_other), isNull);
      expect(room.otherUser(_me), isNull);
      expect(room.unreadCount, 4);
    });

    test('equality covers the content, not only the id', () {
      final room = ChatRoom.fromJson(_roomRow(), currentUserId: _me);
      expect(ChatRoom.fromJson(_roomRow(), currentUserId: _me), room);
      expect(
        ChatRoom.fromJson(_roomRow(), currentUserId: _me).hashCode,
        room.hashCode,
      );

      // A new message in a room already on top: same id, same position.
      final bumped = ChatRoom.fromJson(
        _roomRow(unread: 1)
          ..['lastMessages'] = [
            {
              'id': 'm2',
              'authorId': _other,
              'roomId': 'r1',
              'type': 'text',
              'text': 'Newer one',
              'createdAt': '2026-10-02T00:00:00+00:00',
            },
          ],
        currentUserId: _me,
      );
      expect(bumped, isNot(room));
      expect(room.copyWith(unreadCount: 3), isNot(room));
    });

    test('parses dates, metadata and the last message', () {
      final room = ChatRoom.fromJson(_roomRow(), currentUserId: _me);
      expect(room.updatedAt, DateTime.utc(2026, 10, 2));
      expect(room.metadata, {'workspaceId': 'w1'});
      expect((room.lastMessage as core.TextMessage?)?.text, 'Last one');
    });

    test('tolerates a row without users or last messages', () {
      final room = ChatRoom.fromJson({'id': 'r2', 'type': 'group'});
      expect(room.users, isEmpty);
      expect(room.lastMessage, isNull);
      expect(room.unreadCount, 0);
    });
  });

  group('SupabaseChatCore.applyRoomChange', () {
    ChatRoom room(String id, int day) => ChatRoom(
      id: id,
      type: ChatRoomType.group,
      users: const [],
      updatedAt: DateTime.utc(2026, 10, day),
    );

    test('upserts and sorts by updatedAt, most recent first', () {
      var rooms = [room('a', 1), room('b', 2)];
      rooms = SupabaseChatCore.applyRoomChange(
        rooms,
        ChatRoomUpserted(room('a', 3)),
      );
      expect(rooms.map((r) => r.id), ['a', 'b']);
      rooms = SupabaseChatCore.applyRoomChange(
        rooms,
        ChatRoomUpserted(room('c', 4)),
      );
      expect(rooms.map((r) => r.id), ['c', 'a', 'b']);
    });

    test('removes rooms', () {
      final rooms = SupabaseChatCore.applyRoomChange([
        room('a', 1),
        room('b', 2),
      ], const ChatRoomRemoved('a'));
      expect(rooms.map((r) => r.id), ['b']);
    });

    test('onlyExisting ignores unknown rooms', () {
      final rooms = SupabaseChatCore.applyRoomChange(
        [room('a', 1)],
        ChatRoomUpserted(room('z', 9)),
        onlyExisting: true,
      );
      expect(rooms.map((r) => r.id), ['a']);
    });

    test('rooms without updatedAt sort last', () {
      const undated = ChatRoom(id: 'u', type: ChatRoomType.group, users: []);
      final rooms = SupabaseChatCore.applyRoomChange([
        undated,
      ], ChatRoomUpserted(room('a', 1)));
      expect(rooms.map((r) => r.id), ['a', 'u']);
    });
  });

  group('SupabaseChatCoreConfig', () {
    test('defaults match the SQL scripts', () {
      const config = SupabaseChatCoreConfig();
      expect(config.schema, 'chats');
      expect(config.roomsViewName, 'rooms_l');
      expect(config.realtimeRoomChannelPrefix, 'chats:room:');
      expect(config.usersViewName, 'users');
    });

    test('usersViewName follows usersTableName unless set', () {
      const custom = SupabaseChatCoreConfig(usersTableName: 'people');
      expect(custom.usersViewName, 'people');
      expect(
        custom.copyWith(usersViewName: 'people_l').usersViewName,
        'people_l',
      );
      expect(custom.copyWith(schema: 'x').usersViewName, 'people');
    });

    test('copyWith keeps the hooks', () {
      final config = const SupabaseChatCoreConfig().copyWith(
        defaultRoomMetadata: () => {'w': 1},
        roomFilter: (room) => false,
      );
      final copy = config.copyWith(schema: 'other');
      expect(copy.defaultRoomMetadata?.call(), {'w': 1});
      expect(
        copy.roomFilter?.call(
          const ChatRoom(id: 'r', type: ChatRoomType.group, users: []),
        ),
        isFalse,
      );
    });
  });

  test('chatRoomRoleFromName', () {
    expect(chatRoomRoleFromName('admin'), ChatRoomRole.admin);
    expect(chatRoomRoleFromName(null), isNull);
    expect(chatRoomRoleFromName('nope'), isNull);
  });

  group('ChatForwardOrigin', () {
    test('round-trips through the message metadata', () {
      final origin = ChatForwardOrigin(
        authorId: _other,
        authorName: 'Bob',
        createdAt: DateTime.utc(2026, 10, 2, 8),
      );
      final message = core.Message.text(
        id: 'm1',
        authorId: _me,
        text: 'hi',
        metadata: {ChatForwardOrigin.metadataKey: origin.toJson()},
      );
      final read = ChatForwardOrigin.of(message)!;
      expect(read.authorId, _other);
      expect(read.authorName, 'Bob');
      expect(read.createdAt, DateTime.utc(2026, 10, 2, 8));
    });

    test('is null for a message that was not forwarded', () {
      final message = core.Message.text(id: 'm1', authorId: _me, text: 'hi');
      expect(ChatForwardOrigin.of(message), isNull);
    });

    test('a forward claim only names the source message', () {
      final claim = ChatForwardOrigin.claim(
        sourceRoomId: 'r1',
        sourceMessageId: 'm1',
      );
      expect(claim, {'sourceRoomId': 'r1', 'sourceMessageId': 'm1'});
      final message = core.Message.text(
        id: 'm2',
        authorId: _me,
        text: 'hi',
        metadata: {ChatForwardOrigin.metadataKey: claim},
      );
      expect(ChatForwardOrigin.of(message), isNull);
    });
  });

  group('SupabaseChatCore.httpSupabaseHeadersFor', () {
    final chat = SupabaseChatCore(
      client: SupabaseClient('http://127.0.0.1:54321', 'anon-key'),
    );
    tearDownAll(chat.dispose);

    test('recognizes only this project storage object URLs', () {
      expect(chat.isStorageObjectUrl(chat.getAssetUrl('r1/a.png')), isTrue);
      expect(
        chat.isStorageObjectUrl(
          chat.getAssetUrl('u1/a.png', bucket: 'chats_user_avatar'),
        ),
        isTrue,
      );
      for (final url in [
        'https://attacker.example/avatar.png',
        'https://attacker.example/storage/v1/object/authenticated/x.png',
        'http://127.0.0.1:9999/storage/v1/object/authenticated/x.png',
        'http://127.0.0.1:54321/rest/v1/messages',
        'http://127.0.0.1:54321/storage/v1/object/authenticated/../x.png',
        'not a url',
        '',
      ]) {
        expect(chat.isStorageObjectUrl(url), isFalse, reason: url);
      }
    });

    test('sends no credentials when signed out', () {
      expect(chat.httpSupabaseHeadersFor(chat.getAssetUrl('r1/a.png')), {});
    });
  });
}
