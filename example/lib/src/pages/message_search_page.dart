import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../utils/format.dart';
import '../widgets/empty_state.dart';
import '../widgets/user_avatar.dart';

/// Search messages of a room by text. Pops the tapped message, so the
/// caller can jump to it.
class MessageSearchPage extends StatefulWidget {
  const MessageSearchPage({super.key, required this.room});

  final ChatRoom room;

  @override
  State<MessageSearchPage> createState() => _MessageSearchPageState();
}

class _MessageSearchPageState extends State<MessageSearchPage> {
  Timer? _debounce;
  String _query = '';
  List<core.Message> _results = const [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() {
      _query = query.trim();
      _loading = _query.isNotEmpty;
    });
    if (_query.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    try {
      final results = await SupabaseChatCore.instance.searchMessages(
        widget.room.id,
        _query,
      );
      if (mounted && query.trim() == _query) {
        setState(() => _results = results);
      }
    } on SupabaseChatCoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: ${e.cause ?? e}')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Highlights every case-insensitive occurrence of the query.
  TextSpan _highlight(String text, TextStyle? base, Color color) {
    if (_query.isEmpty) return TextSpan(text: text, style: base);
    final lower = text.toLowerCase();
    final needle = _query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final index = lower.indexOf(needle, start);
      if (index < 0) break;
      spans
        ..add(TextSpan(text: text.substring(start, index)))
        ..add(
          TextSpan(
            text: text.substring(index, index + needle.length),
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        );
      start = index + needle.length;
    }
    spans.add(TextSpan(text: text.substring(start)));
    return TextSpan(style: base, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          autofocus: true,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: const InputDecoration(
            hintText: 'Search messages',
            filled: false,
            border: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: _query.isEmpty
          ? const EmptyState(
              icon: Icons.manage_search_rounded,
              title: 'Search this chat',
              message: 'Type a word to find messages containing it.',
            )
          : _results.isEmpty && !_loading
          ? const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No results',
              message: 'Try a different word.',
            )
          : ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, _) => const Divider(indent: 72),
              itemBuilder: (context, index) {
                final message = _results[index];
                final author = widget.room.member(message.authorId);
                final text = message is core.TextMessage ? message.text : '';
                return ListTile(
                  leading: author == null
                      ? const CircleAvatar(child: Icon(Icons.person_outline))
                      : UserAvatar.user(author),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          author?.fullName ?? 'Unknown',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        formatListTime(context, message.createdAt),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                  subtitle: Text.rich(
                    _highlight(
                      text,
                      theme.textTheme.bodyMedium,
                      theme.colorScheme.primary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.of(context).pop(message),
                );
              },
            ),
    );
  }
}
