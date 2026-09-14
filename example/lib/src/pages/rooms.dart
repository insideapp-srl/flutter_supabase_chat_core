import 'package:flutter/material.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';

import '../widgets/room_tile.dart';
import 'room.dart';

class RoomsPage extends StatefulWidget {
  const RoomsPage({super.key});

  @override
  State<RoomsPage> createState() => _RoomsPageState();
}

class _RoomsPageState extends State<RoomsPage> {
  static const _pageSize = 20;
  String _filter = '';

  late final PagingController<int, ChatRoom> _controller =
      PagingController<int, ChatRoom>(
        getNextPageKey: (state) =>
            state.lastPageIsEmpty ? null : (state.items?.length ?? 0),
        fetchPage: (pageKey) => SupabaseChatCore.instance.rooms(
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

  @override
  Widget build(BuildContext context) => Column(
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
        child: RefreshIndicator(
          onRefresh: () async {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _controller.refresh();
              }
            });
          },
          child: StreamBuilder<List<ChatRoom>>(
            stream: SupabaseChatCore.instance.roomsUpdates(),
            builder: (context, snapshot) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _filter == '' && snapshot.data != null) {
                  final merged = SupabaseChatCore.updateRoomList(
                    _controller.items ?? [],
                    snapshot.data!,
                  );
                  _controller.value = _controller.value.copyWith(
                    pages: [merged],
                    keys: [0],
                  );
                }
              });
              return PagingListener<int, ChatRoom>(
                controller: _controller,
                builder: (context, state, fetchNextPage) =>
                    PagedListView<int, ChatRoom>(
                      state: state,
                      fetchNextPage: fetchNextPage,
                      builderDelegate: PagedChildBuilderDelegate<ChatRoom>(
                        itemBuilder: (context, room, index) => RoomTile(
                          room: room,
                          onTap: (room) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => RoomPage(room: room),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
              );
            },
          ),
        ),
      ),
    ],
  );
}
