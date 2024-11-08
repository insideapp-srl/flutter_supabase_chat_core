import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
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

  final PagingController<int, types.User> _controller =
      PagingController(firstPageKey: 0);

  @override
  void initState() {
    _controller.addPageRequestListener((pageKey) {
      _fetchPage(pageKey);
    });
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setFilters(String filter) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _filter = filter;
      if (mounted) {
        _controller.nextPageKey = 0;
        _controller.refresh();
      }
    });
  }

  Future<void> _fetchPage(int offset) async {
    try {
      final newItems = await SupabaseChatCore.instance
          .users(filter: _filter, offset: offset, limit: _pageSize);
      final isLastPage = newItems.length < _pageSize;
      if (isLastPage) {
        _controller.appendLastPage(newItems);
      } else {
        final nextPageKey = offset + newItems.length;
        _controller.appendPage(newItems, nextPageKey);
      }
    } catch (error) {
      _controller.error = error;
    }
  }

  void _handlePressed(types.User otherUser, BuildContext context) async {
    final navigator = Navigator.of(context);
    final room = await SupabaseChatCore.instance.createRoom(otherUser);

    navigator.pop();
    await navigator.push(
      MaterialPageRoute(
        builder: (context) => RoomPage(
          room: room,
        ),
      ),
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
              child: PagedListView<int, types.User>(
                pagingController: _controller,
                builderDelegate: PagedChildBuilderDelegate<types.User>(
                  itemBuilder: (context, user, index) => UserTile(
                    user: user,
                    onTap: (user) {
                      _handlePressed(user, context);
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
