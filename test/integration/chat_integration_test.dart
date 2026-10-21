@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'harness.dart';

core.Message _text(TestUser author, String text) =>
    core.Message.text(id: const Uuid().v7(), authorId: author.id, text: text);

void main() {
  late TestUser alice;
  late TestUser bob;
  late TestUser carol;
  // Set once setUpAll created every user: tearDownAll must not touch the
  // late fields when setUpAll failed half-way.
  var ready = false;

  setUpAll(() async {
    if (skipReason != null) return;
    alice = await TestUser.create('Alice', 'Liddell');
    bob = await TestUser.create('Bob', 'Builder');
    carol = await TestUser.create('Carol', 'Danvers');
    ready = true;
  });

  tearDownAll(() async {
    if (skipReason != null || !ready) return;
    await alice.dispose();
    await bob.dispose();
    await carol.dispose();
  });

  group('users', skip: skipReason, () {
    test('profiles are created from sign-up metadata', () async {
      expect(alice.chat.loggedUser?.fullName, 'Alice Liddell');
      final fetched = await bob.chat.user(uid: alice.id);
      expect(fetched?.firstName, 'Alice');
      expect(fetched?.initials, 'AL');
    });

    test('search matches every word against first/last name', () async {
      final found = await alice.chat.users(filter: 'bob build', limit: 100);
      expect(found.map((u) => u.id), contains(bob.id));
      final none = await alice.chat.users(filter: 'bob danvers', limit: 100);
      expect(none.map((u) => u.id), isNot(contains(bob.id)));
    });

    test('excludeLoggedUser leaves the caller out', () async {
      final all = await alice.chat.users(limit: 1000, excludeLoggedUser: true);
      expect(all.map((u) => u.id), isNot(contains(alice.id)));
    });

    test('a filter with PostgREST syntax characters is safe', () async {
      final found = await alice.chat.users(filter: 'a,b) or(x."', limit: 5);
      expect(found, isEmpty);
    });

    test('updateUser updates the own profile only', () async {
      await alice.chat.updateUser(
        alice.chat.loggedUser!.copyWith(metadata: {'bio': 'hi'}),
      );
      expect((await bob.chat.user(uid: alice.id))?.metadata, {'bio': 'hi'});

      await bob.chat.updateUser(alice.asChatUser.copyWith(firstName: 'Evil'));
      expect((await bob.chat.user(uid: alice.id))?.firstName, 'Alice');
    });
  });

  group('rooms', skip: skipReason, () {
    test(
      'a direct room is created once and named after the other user',
      () async {
        final fromAlice = await alice.chat.createRoom(bob.asChatUser);
        final fromBob = await bob.chat.createRoom(alice.asChatUser);
        expect(fromBob.id, fromAlice.id);
        expect(fromAlice.type, ChatRoomType.direct);
        expect(fromAlice.name, 'Bob Builder');
        expect(fromBob.name, 'Alice Liddell');
        expect(
          fromAlice.users.map((u) => u.id),
          unorderedEquals([alice.id, bob.id]),
        );
      },
    );

    test('a direct room with yourself is rejected', () async {
      expect(
        () => alice.chat.createRoom(alice.asChatUser),
        throwsA(isA<SupabaseChatCoreRequestException>()),
      );
    });

    test('a group room gets its members and the creator is admin', () async {
      final room = await alice.chat.createGroupRoom(
        name: 'Wonderland',
        users: [bob.asChatUser, carol.asChatUser],
        metadata: {'topic': 'tea'},
      );
      expect(room.type, ChatRoomType.group);
      expect(room.name, 'Wonderland');
      expect(room.metadata, {'topic': 'tea'});
      expect(room.roleOf(alice.id), ChatRoomRole.admin);
      expect(room.roleOf(bob.id), isNull);
      expect(room.users, hasLength(3));
    });

    test('only admins rename a group, members can leave it', () async {
      final room = await alice.chat.createGroupRoom(
        name: 'Admins only',
        users: [bob.asChatUser],
      );
      await bob.chat.updateRoom(room.copyWith(name: 'Hijacked'));
      expect((await alice.chat.getRoom(room.id))?.name, 'Admins only');

      await alice.chat.updateRoom(room.copyWith(name: 'Renamed'));
      expect((await bob.chat.getRoom(room.id))?.name, 'Renamed');

      await alice.chat.addMembers(room.id, [carol.id]);
      expect((await carol.chat.getRoom(room.id))?.users, hasLength(3));

      await alice.chat.setMemberRole(room.id, carol.id, ChatRoomRole.moderator);
      expect(
        (await carol.chat.getRoom(room.id))?.roleOf(carol.id),
        ChatRoomRole.moderator,
      );

      await bob.chat.leaveRoom(room.id);
      expect(await bob.chat.getRoom(room.id), isNull);
      expect((await alice.chat.getRoom(room.id))?.users, hasLength(2));

      await alice.chat.removeMember(room.id, carol.id);
      expect(await carol.chat.getRoom(room.id), isNull);
    });

    test('rooms are paginated and searchable', () async {
      final user = await TestUser.create('Paula', 'Pager');
      addTearDown(user.dispose);
      for (var i = 0; i < 5; i++) {
        await user.chat.createGroupRoom(name: 'Page room $i', users: []);
      }
      final first = await user.chat.rooms(limit: 3);
      final second = await user.chat.rooms(offset: 3, limit: 3);
      expect(first, hasLength(3));
      expect(second, hasLength(2));
      expect({...first, ...second}, hasLength(5));
      expect(first.first.name, 'Page room 4', reason: 'newest first');

      final searched = await user.chat.rooms(filter: 'room 2');
      expect(searched.map((r) => r.name), ['Page room 2']);
    });

    test('scoping hooks keep each scope separate', () async {
      var scope = 'w1';
      final config = const SupabaseChatCoreConfig().copyWith(
        defaultRoomMetadata: () => {'workspaceId': scope},
        roomsQueryFilter: (q) => q.eq('metadata->>workspaceId', scope),
        roomFilter: (room) => room.metadata?['workspaceId'] == scope,
      );
      final dan = await TestUser.create('Dan', 'Scoped', config: config);
      final eve = await TestUser.create('Eve', 'Scoped', config: config);
      addTearDown(dan.dispose);
      addTearDown(eve.dispose);

      final inW1 = await dan.chat.createRoom(eve.asChatUser);
      scope = 'w2';
      final inW2 = await dan.chat.createRoom(eve.asChatUser);
      expect(inW2.id, isNot(inW1.id), reason: 'one direct room per scope');
      expect(inW2.metadata, {'workspaceId': 'w2'});

      expect((await dan.chat.rooms()).map((r) => r.id), [inW2.id]);
      scope = 'w1';
      expect((await eve.chat.rooms()).map((r) => r.id), [inW1.id]);
      expect((await dan.chat.createRoom(eve.asChatUser)).id, inW1.id);
    });
  });

  group('messages', skip: skipReason, () {
    late ChatRoom room;

    setUp(() async {
      room = await alice.chat.createGroupRoom(
        name: 'Messages ${const Uuid().v4()}',
        users: [bob.asChatUser],
      );
    });

    test('a message is delivered in real time and reconciled', () async {
      final aliceController = SupabaseChatController(
        room: room,
        chatCore: alice.chat,
        autoMarkAsRead: false,
      );
      final bobController = SupabaseChatController(
        room: room,
        chatCore: bob.chat,
        autoMarkAsRead: false,
      );
      addTearDown(aliceController.dispose);
      addTearDown(bobController.dispose);
      await Future.wait([
        aliceController.initialLoad,
        bobController.initialLoad,
      ]);
      await realtimeReady(alice.client);
      await realtimeReady(bob.client);

      final message = _text(alice, 'Hello Bob');
      final sending = aliceController.sendMessage(message);
      expect(
        aliceController.messages.single.status,
        core.MessageStatus.sending,
      );
      await sending;

      await eventually(
        () => bobController.messages.any((m) => m.id == message.id),
      );
      final received = bobController.messages.single as core.TextMessage;
      expect(received.text, 'Hello Bob');
      expect(received.authorId, alice.id);
      expect(received.status, core.MessageStatus.sent);
      expect(
        aliceController.messages,
        hasLength(1),
        reason: 'no duplicate echo',
      );
      expect(aliceController.messages.single.status, core.MessageStatus.sent);

      final updatedRoom = await bob.chat.getRoom(room.id);
      expect(
        (updatedRoom?.lastMessage as core.TextMessage?)?.text,
        'Hello Bob',
      );
      expect(updatedRoom?.unreadCount, 1);
    });

    test('read receipts flow back to the sender', () async {
      final aliceController = SupabaseChatController(
        room: room,
        chatCore: alice.chat,
        autoMarkAsRead: false,
      );
      addTearDown(aliceController.dispose);
      await aliceController.initialLoad;
      await realtimeReady(alice.client);

      final message = _text(alice, 'Did you read this?');
      await aliceController.sendMessage(message);

      final bobController = SupabaseChatController(
        room: room,
        chatCore: bob.chat,
      );
      addTearDown(bobController.dispose);
      await bobController.initialLoad;

      await eventually(
        () => aliceController.messages.single.status == core.MessageStatus.seen,
        reason: 'status seen not received',
      );
      expect((await bob.chat.getRoom(room.id))?.unreadCount, 0);
    });

    test('pagination loads every older message exactly once', () async {
      for (var i = 0; i < 25; i++) {
        await alice.chat.sendMessage(
          core.Message.text(
            id: const Uuid().v7(),
            authorId: alice.id,
            text: 'm$i',
            createdAt: DateTime.now().toUtc().add(Duration(milliseconds: i)),
          ),
          room.id,
        );
      }
      final controller = SupabaseChatController(
        room: room,
        chatCore: bob.chat,
        pageSize: 10,
        autoMarkAsRead: false,
      );
      addTearDown(controller.dispose);
      await controller.initialLoad;
      expect(controller.messages, hasLength(10));
      expect((controller.messages.last as core.TextMessage).text, 'm24');

      while (controller.hasMoreMessages) {
        await controller.loadPreviousMessages();
      }
      final texts = controller.messages
          .map((m) => (m as core.TextMessage).text)
          .toList();
      expect(texts, [for (var i = 0; i < 25; i++) 'm$i']);
    });

    test('edits, reactions and deletions propagate', () async {
      final aliceController = SupabaseChatController(
        room: room,
        chatCore: alice.chat,
        autoMarkAsRead: false,
      );
      final bobController = SupabaseChatController(
        room: room,
        chatCore: bob.chat,
        autoMarkAsRead: false,
      );
      addTearDown(aliceController.dispose);
      addTearDown(bobController.dispose);
      await Future.wait([
        aliceController.initialLoad,
        bobController.initialLoad,
      ]);
      await realtimeReady(alice.client);
      await realtimeReady(bob.client);

      final message = _text(alice, 'Typo');
      await aliceController.sendMessage(message);
      await eventually(() => bobController.messages.isNotEmpty);

      await aliceController.editTextMessage(
        aliceController.messages.single as core.TextMessage,
        'Fixed',
      );
      await eventually(
        () =>
            (bobController.messages.single as core.TextMessage).text == 'Fixed',
      );
      expect(bobController.messages.single.metadata?['edited'], true);

      await bobController.toggleReaction(message.id, '❤️');
      await eventually(
        () =>
            aliceController.messages.single.reactions?['❤️']?.contains(
              bob.id,
            ) ??
            false,
      );

      expect(
        await bobController.deleteMessage(message.id),
        isFalse,
        reason: 'members cannot delete other members messages',
      );
      expect(await aliceController.deleteMessage(message.id), isTrue);
      await eventually(() => bobController.messages.isEmpty);
    });

    test(
      'a failed send is kept with status error and can be retried',
      () async {
        final outsider = await TestUser.create('Olga', 'Outsider');
        addTearDown(outsider.dispose);
        final controller = SupabaseChatController(
          room: room,
          chatCore: outsider.chat,
          autoMarkAsRead: false,
        );
        addTearDown(controller.dispose);
        await controller.initialLoad;

        final message = _text(outsider, 'Let me in');
        await expectLater(
          controller.sendMessage(message),
          throwsA(isA<SupabaseChatCoreRequestException>()),
        );
        expect(controller.messages.single.status, core.MessageStatus.error);
        expect(await controller.deleteMessage(message.id), isTrue);
        expect(controller.messages, isEmpty);
      },
    );

    test('voice messages keep duration and waveform end to end', () async {
      final controller = SupabaseChatController(
        room: room,
        chatCore: bob.chat,
        autoMarkAsRead: false,
      );
      addTearDown(controller.dispose);
      await controller.initialLoad;
      await realtimeReady(bob.client);

      // A tiny fake recording: the bytes don't need to be valid audio here.
      final bytes = Uint8List.fromList(List.generate(2048, (i) => i % 256));
      final upload = await alice.chat.uploadAsset(room, 'voice.webm', bytes);
      final message = core.Message.audio(
        id: const Uuid().v7(),
        authorId: alice.id,
        source: upload.url,
        duration: const Duration(seconds: 7),
        size: bytes.length,
        waveform: const [0.1, 0.5, 1.0, 0.25],
      );
      await alice.chat.sendMessage(message, room.id);

      await eventually(
        () => controller.messages.any((m) => m.id == message.id),
      );
      final received = controller.messages.single as core.AudioMessage;
      expect(received.duration, const Duration(seconds: 7));
      expect(received.waveform, [0.1, 0.5, 1.0, 0.25]);
      expect(received.source, upload.url);
      final downloaded = await bob.client.storage
          .from('chats_assets')
          .download(upload.path!);
      expect(downloaded, bytes);
      final updatedRoom = await bob.chat.getRoom(room.id);
      expect(updatedRoom?.lastMessage, isA<core.AudioMessage>());
    });

    test('attachments are readable by members only', () async {
      final bytes = Uint8List.fromList(utf8.encode('hello file'));
      final upload = await alice.chat.uploadAsset(
        room,
        'notes (v2).txt',
        bytes,
      );
      expect(upload.mimeType, 'text/plain');
      expect(upload.path, startsWith('${room.id}/'));
      expect(upload.url, contains('/object/authenticated/chats_assets/'));

      final downloaded = await bob.client.storage
          .from('chats_assets')
          .download(upload.path!);
      expect(utf8.decode(downloaded), 'hello file');

      await expectLater(
        carol.client.storage.from('chats_assets').download(upload.path!),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('telegram-like features', skip: skipReason, () {
    test('rooms can be pinned on top and muted, per user', () async {
      final user = await TestUser.create('Tina', 'Telegram');
      addTearDown(user.dispose);
      final older = await user.chat.createGroupRoom(
        name: 'Older',
        users: [alice.asChatUser],
      );
      await user.chat.createGroupRoom(name: 'Newer', users: [alice.asChatUser]);
      expect((await user.chat.rooms()).first.name, 'Newer');

      await user.chat.pinRoom(older.id);
      final rooms = await user.chat.rooms();
      expect(rooms.first.id, older.id);
      expect(rooms.first.isPinned, isTrue);
      expect(
        (await alice.chat.getRoom(older.id))?.isPinned,
        isFalse,
        reason: 'per user',
      );

      await user.chat.muteRoom(older.id);
      expect((await user.chat.getRoom(older.id))?.isMuted, isTrue);
      expect(
        (await user.chat.getRoom(older.id))?.mutedUntil,
        ChatRoom.mutedForever,
      );
      await user.chat.muteRoom(older.id, duration: const Duration(hours: 1));
      expect((await user.chat.getRoom(older.id))?.isMuted, isTrue);
      await user.chat.unmuteRoom(older.id);
      expect((await user.chat.getRoom(older.id))?.isMuted, isFalse);

      await user.chat.pinRoom(older.id, pinned: false);
      expect((await user.chat.rooms()).first.name, 'Newer');
    });

    test('messages can be pinned, searched and replied to', () async {
      final room = await alice.chat.createGroupRoom(
        name: 'Pins',
        users: [bob.asChatUser],
      );
      final controller = SupabaseChatController(
        room: room,
        chatCore: bob.chat,
        autoMarkAsRead: false,
      );
      addTearDown(controller.dispose);
      await controller.initialLoad;
      await realtimeReady(bob.client);

      final original = _text(alice, 'The meeting is at 10:00');
      await alice.chat.sendMessage(original, room.id);
      await alice.chat.sendMessage(
        core.Message.text(
          id: const Uuid().v7(),
          authorId: alice.id,
          text: 'Bring the slides',
          replyToMessageId: original.id,
        ),
        room.id,
      );
      await eventually(() => controller.messages.length == 2);
      final reply = controller.messages.last;
      expect(reply.replyToMessageId, original.id);
      final quoted = await controller.resolveMessage(reply.replyToMessageId!);
      expect((quoted as core.TextMessage?)?.text, 'The meeting is at 10:00');

      await expectLater(
        bob.chat.setMessagePinned(original.id),
        throwsA(isA<SupabaseChatCoreRequestException>()),
        reason: 'only admins pin in groups',
      );
      await alice.chat.setMessagePinned(original.id);
      await eventually(() => controller.pinnedMessages.value.length == 1);
      expect(controller.pinnedMessages.value.single.id, original.id);
      await alice.chat.setMessagePinned(original.id, pinned: false);
      await eventually(() => controller.pinnedMessages.value.isEmpty);

      final found = await bob.chat.searchMessages(room.id, 'MEETING');
      expect(found.map((m) => m.id), [original.id]);
      expect(
        await bob.chat.searchMessages(room.id, 'nothing like this'),
        isEmpty,
      );
    });
  });

  group('realtime', skip: skipReason, () {
    test('typing indicator uses throttled broadcast (issue #38)', () async {
      final room = await alice.chat.createGroupRoom(
        name: 'Typing',
        users: [bob.asChatUser],
      );
      final aliceController = SupabaseChatController(
        room: room,
        chatCore: alice.chat,
      );
      final bobController = SupabaseChatController(
        room: room,
        chatCore: bob.chat,
      );
      addTearDown(aliceController.dispose);
      addTearDown(bobController.dispose);
      await realtimeReady(alice.client);
      await realtimeReady(bob.client);

      final events = <List<String>>[];
      final sub = bobController.typingUsers.listen(
        (users) => events.add(users.map((u) => u.id).toList()),
      );
      addTearDown(sub.cancel);

      // 20 keystrokes in ~1s: far beyond Presence's rate limit, but only one
      // broadcast goes out.
      for (var i = 0; i < 20; i++) {
        aliceController.onTyping();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await eventually(() => bobController.currentTypingUsers.isNotEmpty);
      expect(bobController.currentTypingUsers.single.id, alice.id);
      expect(
        events.where((e) => e.isNotEmpty).length,
        1,
        reason: 'throttled to a single typing event',
      );

      await aliceController.endTyping();
      await eventually(() => bobController.currentTypingUsers.isEmpty);
      expect(
        aliceController.currentTypingUsers,
        isEmpty,
        reason: 'own typing is never reported',
      );
    });

    test('roomsChanges reports new, updated and left rooms', () async {
      final rita = await TestUser.create('Rita', 'Realtime');
      addTearDown(rita.dispose);
      final changes = <ChatRoomChange>[];
      final errors = <Object>[];
      final sub = rita.chat.roomsChanges().listen(
        changes.add,
        onError: errors.add,
      );
      addTearDown(sub.cancel);
      await realtimeReady(rita.client);

      final room = await alice.chat.createGroupRoom(
        name: 'Changes',
        users: [rita.asChatUser],
      );
      await eventually(
        () => changes.any((c) => c is ChatRoomUpserted && c.room.id == room.id),
        reason: 'added-to-room upsert (errors: $errors)',
      );

      changes.clear();
      await alice.chat.sendMessage(_text(alice, 'ping'), room.id);
      await eventually(
        () => changes.any(
          (c) =>
              c is ChatRoomUpserted &&
              c.room.id == room.id &&
              c.room.unreadCount == 1,
        ),
        reason: 'new-message upsert',
      );

      await rita.chat.leaveRoom(room.id);
      await eventually(
        () => changes.any((c) => c is ChatRoomRemoved && c.roomId == room.id),
        reason: 'left-room removal',
      );
    });

    test('SupabaseChatRoomsController keeps its list in sync', () async {
      final dora = await TestUser.create('Dora', 'Explorer');
      addTearDown(dora.dispose);
      final controller = SupabaseChatRoomsController(chatCore: dora.chat);
      addTearDown(controller.dispose);
      await controller.loadFirstPage();
      expect(controller.rooms, isEmpty);
      await realtimeReady(dora.client);

      final first = await alice.chat.createGroupRoom(
        name: 'One',
        users: [dora.asChatUser],
      );
      final second = await alice.chat.createGroupRoom(
        name: 'Two',
        users: [dora.asChatUser],
      );
      await eventually(() => controller.rooms.length == 2);
      expect(controller.rooms.first.id, second.id);

      await alice.chat.sendMessage(_text(alice, 'bump'), first.id);
      await eventually(() => controller.rooms.first.id == first.id);
      expect(controller.totalUnreadCount, 1);

      await alice.chat.deleteRoom(second.id);
      await eventually(() => controller.rooms.length == 1);
    });

    test('online status is shared over presence', () async {
      final statuses = <UserOnlineStatus>[];
      final sub = bob.chat.userOnlineStatus(alice.id).listen(statuses.add);
      addTearDown(sub.cancel);
      await realtimeReady(bob.client);
      await realtimeReady(alice.client);

      await alice.chat.setPresenceStatus(UserOnlineStatus.online);
      await eventually(() => statuses.lastOrNull == UserOnlineStatus.online);

      await alice.chat.setPresenceStatus(UserOnlineStatus.offline);
      await eventually(() => statuses.last == UserOnlineStatus.offline);
      final profile = await bob.chat.user(uid: alice.id);
      expect(profile?.lastSeen, isNotNull);
    });
  });
}
