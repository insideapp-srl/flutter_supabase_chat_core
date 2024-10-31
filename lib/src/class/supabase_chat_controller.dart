import 'dart:async';

import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../flutter_supabase_chat_core.dart';

/// Provides Supabase chat controller. Instance new class
/// SupabaseChatController to manage a chat.
class SupabaseChatController {
  late types.Room _room;
  final List<types.Message> _messages = [];
  final int pageSize;
  int _currentPage = 0;
  final _messagesController = StreamController<List<types.Message>>();
  final _typingController = StreamController<List<types.User>>();
  late RealtimeChannel _typingChannel;
  bool _typingChannelSubscribed = false;
  Timer? _throttleTimer;
  Timer? _endTypingTimer;

  /// SupabaseChatController constructor
  /// [pageSize] define a pagination size
  /// [room] is required, is the controller's reference to the room
  SupabaseChatController({
    this.pageSize = 10,
    required types.Room room,
  }) {
    _room = room;
    _typingChannel = client.channel(
      '${config.realtimeChatTypingUserPrefixChannel}${_room.id}',
      opts: RealtimeChannelConfig(
        key: 'typing-state',
      ),
    );
    _typingChannel.onPresenceSync((_) {
      final newState = _typingChannel.presenceState();
      var typingUsers = <types.User>[];
      final keyIndex = newState.indexWhere(
        (e) => e.key == 'typing-state',
      );
      if (keyIndex >= 0) {
        final users = newState[keyIndex]
            .presences
            .where((e) => e.payload['typing'] == true)
            .map(
              (e) => e.payload['uid'].toString(),
            )
            .toList();
        typingUsers = _room.users
            .where(
              (e) => users.contains(e.id) && e.id != SupabaseChatCore.instance.supabaseUser!.id,
            )
            .toList();
      }
      _typingController.sink.add(typingUsers);
    }).subscribe(
      (status, error) {
        _typingChannelSubscribed = status == RealtimeSubscribeStatus.subscribed;
      },
    );
  }

  /// return a SupabaseClient instance
  SupabaseClient get client => SupabaseChatCore.instance.client;

  /// return a SupabaseChatCoreConfig instance
  SupabaseChatCoreConfig get config => SupabaseChatCore.instance.config;

  PostgrestTransformBuilder _messagesQuery() => client
      .schema(config.schema)
      .from(config.messagesTableName)
      .select()
      .eq('roomId', int.parse(_room.id))
      .order('createdAt', ascending: false)
      .range(pageSize * _currentPage, (_currentPage * pageSize) + pageSize);

  void _onData(List<Map<String, dynamic>> data) {
    for (var val in data) {
      final author = _room.users.firstWhere(
        (u) => u.id == val['authorId'],
        orElse: () => types.User(id: val['authorId'] as String),
      );
      val['author'] = author.toJson();
      val['id'] = val['id'].toString();
      val['roomId'] = val['roomId'].toString();
      final newMessage = types.Message.fromJson(val);
      final index = _messages.indexWhere((msg) => msg.id == newMessage.id);
      if (index != -1) {
        _messages[index] = newMessage;
      } else {
        _messages.add(newMessage);
      }
    }
    _messages.sort(
      (a, b) => b.createdAt?.compareTo(a.createdAt ?? 0) ?? -1,
    );
    _messagesController.sink.add(_messages);
  }

  /// Returns a stream of messages from Supabase for a specified room.
  /// Only the amount of messages specified in [pageSize] will be loaded,
  /// then it will be necessary to call the [loadPreviousMessages] method to get
  /// the next page of messages
  Stream<List<types.Message>> get messages {
    _messagesQuery().then((value) => _onData(value));
    client
        .channel('${config.schema}:${config.messagesTableName}:${_room.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: config.schema,
          table: config.messagesTableName,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'roomId',
            value: _room.id,
          ),
          callback: (payload) => _onData([payload.newRecord]),
        )
        .subscribe();
    return _messagesController.stream;
  }

  /// This method allows to receive on the stream [messages] the next
  /// page
  Future<void> loadPreviousMessages() async {
    _currentPage += 1;
    await _messagesQuery().then((value) => _onData(value));
  }

  /// Returns a stream of typing users from Supabase for a specified room.
  Stream<List<types.User>> get typingUsers => _typingController.stream;

  void onTyping() async {
    if (_typingChannelSubscribed &&
        SupabaseChatCore.instance.supabaseUser != null) {
      if (_throttleTimer?.isActive ?? false) return;
      _throttleTimer = Timer(Duration(milliseconds: 500), () {});
      _endTypingTimer?.cancel();
      _endTypingTimer = Timer(
        Duration(seconds: 3),
        () async {
          await _typingChannel.track(_typingInfo(false));
        },
      );
      await _typingChannel.track(_typingInfo(true));
    }
  }

  Map<String, dynamic> _typingInfo(bool typing) => {
        'uid': SupabaseChatCore.instance.supabaseUser!.id,
        'timestamp': DateTime.now().toIso8601String(),
        'typing': typing,
      };

  void dispose() {
    _typingChannel.untrack();
  }
}
