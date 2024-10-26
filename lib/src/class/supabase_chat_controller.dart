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
  final _controller = StreamController<List<types.Message>>();

  /// SupabaseChatController constructor
  /// [pageSize] define a pagination size
  /// [room] is required, is the controller's reference to the room
  SupabaseChatController({
    this.pageSize = 10,
    required types.Room room,
  }) {
    _room = room;
  }

  /// return a SupabaseClient instance
  SupabaseClient get client => SupabaseChatCore.instance.client;

  /// return a SupabaseChatCoreConfig instance
  SupabaseChatCoreConfig get config => SupabaseChatCore.instance.config;

  PostgrestTransformBuilder _query() => client
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
    _controller.sink.add(_messages);
  }

  /// Returns a stream of messages from Supabase for a specified room.
  /// Only the amount of messages specified in [pageSize] will be loaded,
  /// then it will be necessary to call the [loadPreviousMessages] method to get
  /// the next page of messages
  Stream<List<types.Message>> get messages {
    _query().then((value) => _onData(value));
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
            callback: (payload) => _onData([payload.newRecord]),)
        .subscribe();
    return _controller.stream;
  }

  /// This method allows to receive on the stream [messages] the next
  /// page
  Future<void> loadPreviousMessages() async {
    _currentPage += 1;
    await _query().then((value) => _onData(value));
  }
}
