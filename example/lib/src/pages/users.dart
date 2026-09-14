import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

import '../widgets/user_tile.dart';
import 'room.dart';

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  static const _pageSize = 20;
  String _filter = '';

  late final PagingController<int, ChatUser> _controller =
      PagingController<int, ChatUser>(
        getNextPageKey: (state) =>
            state.lastPageIsEmpty ? null : (state.items?.length ?? 0),
        fetchPage: (pageKey) => SupabaseChatCore.instance.users(
          filter: _filter,
          offset: pageKey,
          limit: _pageSize,
        ),
      );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setFilters(String filter) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _filter = filter;
      if (mounted) {
        _controller.refresh();
      }
    });
  }

  void _handlePressed(ChatUser otherUser, BuildContext context) async {
    final navigator = Navigator.of(context);
    final room = await SupabaseChatCore.instance.createRoom(otherUser);

    navigator.pop();
    await navigator.push(
      MaterialPageRoute(builder: (context) => RoomPage(room: room)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      systemOverlayStyle: SystemUiOverlayStyle.light,
      title: const Text('Users'),
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FractionallySizedBox(
          widthFactor: .5,
          child: TextField(
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Search',
            ),
            onChanged: (value) => _setFilters(value),
          ),
        ),
        Expanded(
          child: PagingListener<int, ChatUser>(
            controller: _controller,
            builder: (context, state, fetchNextPage) =>
                PagedListView<int, ChatUser>(
                  state: state,
                  fetchNextPage: fetchNextPage,
                  builderDelegate: PagedChildBuilderDelegate<ChatUser>(
                    itemBuilder: (context, user, index) => UserTile(
                      user: user,
                      onTap: (user) {
                        _handlePressed(user, context);
                      },
                    ),
                  ),
                ),
          ),
        ),
      ],
    ),
  );
}
