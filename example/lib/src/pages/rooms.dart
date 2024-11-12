import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
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
                    _controller.nextPageKey = 0;
                    _controller.refresh();
                  }
                });
              },
              child: StreamBuilder<List<types.Room>>(
                stream: SupabaseChatCore.instance.roomsUpdates(),
                builder: (context, snapshot) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      if (_filter == '' && snapshot.data != null) {
                        _controller.itemList = SupabaseChatCore.updateRoomList(
                          _controller.itemList ?? [],
                          snapshot.data!,
                        );
                      }
                    }
                  });
                  return PagedListView<int, types.Room>(
                    pagingController: _controller,
                    builderDelegate: PagedChildBuilderDelegate<types.Room>(
                      itemBuilder: (context, room, index) => RoomTile(
                        room: room,
                        onTap: (room) {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => RoomPage(
                                room: room,
                              ),
                            ),
                          );
                        },
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
