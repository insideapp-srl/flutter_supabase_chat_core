import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:timeago/timeago.dart' as timeago;

import 'chat.dart';
import 'util.dart';

class RoomsPage extends StatefulWidget {
  const RoomsPage({super.key});

  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage> {
  static const _pageSize = 20;
  String _filter = '';

  final PagingController<int, types.Room> _controller =
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
          .rooms(filter: _filter, offset: offset, limit: _pageSize);
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

  Widget _buildAvatar(types.Room room) {
    var color = Colors.transparent;
    types.User? otherUser;

    if (room.type == types.RoomType.direct) {
      try {
        otherUser = room.users.firstWhere(
          (u) => u.id != SupabaseChatCore.instance.loggedSupabaseUser!.id,
        );

        color = getUserAvatarNameColor(otherUser);
      } catch (e) {
        // Do nothing if the other user is not found.
      }
    }

    final hasImage = room.imageUrl != null;
    final name = room.name ?? '';
    final Widget child = CircleAvatar(
      backgroundColor: hasImage ? Colors.transparent : color,
      backgroundImage: hasImage ? NetworkImage(room.imageUrl!) : null,
      radius: 20,
      child: !hasImage
          ? Text(
              name.isEmpty ? '' : name[0].toUpperCase(),
              style: const TextStyle(color: Colors.white),
            )
          : null,
    );
    if (otherUser == null) {
      return Container(
        margin: const EdgeInsets.only(right: 16),
        child: child,
      );
    }

    return Container(
      margin: const EdgeInsets.only(right: 16),
      child: UserOnlineStatusWidget(
        uid: otherUser.id,
        builder: (status) => Stack(
          alignment: Alignment.bottomRight,
          children: [
            child,
            if (status == UserOnlineStatus.online)
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 3, bottom: 3),
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white,
                    width: 2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          TextField(
            onChanged: (value) => _setFilters(value),
          ),
          Expanded(
            child: PagedListView<int, types.Room>(
              pagingController: _controller,
              builderDelegate: PagedChildBuilderDelegate<types.Room>(
                itemBuilder: (context, room, index) => ListTile(
                  key: ValueKey(room.id),
                  leading: _buildAvatar(room),
                  title: Text(room.name ?? ''),
                  subtitle: Text(
                    '${timeago.format(DateTime.now().subtract(Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - (room.updatedAt ?? 0))), locale: 'en_short')} ${room.lastMessages != null && room.lastMessages!.isNotEmpty && room.lastMessages!.first is types.TextMessage ? (room.lastMessages!.first as types.TextMessage).text : ''}',
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => ChatPage(
                          room: room,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      );
}
