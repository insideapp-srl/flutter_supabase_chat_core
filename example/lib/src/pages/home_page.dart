import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../widgets/chat_wallpaper.dart';
import '../widgets/empty_state.dart';
import '../widgets/room_tile.dart';
import '../widgets/user_avatar.dart';
import 'new_chat_sheet.dart';
import 'profile_sheet.dart';
import 'room_page.dart';

/// Chats list + conversation, Telegram style. Side by side on wide
/// screens (tablet, desktop, web), list → pushed conversation on phones.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _wideBreakpoint = 840.0;
  final _rooms = SupabaseChatRoomsController()..loadFirstPage();
  final _scroll = ScrollController();
  final _searchController = TextEditingController();
  bool _searching = false;
  ChatRoom? _selected;

  String get _me => SupabaseChatCore.instance.loggedUserId!;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _rooms.loadNextPage();
    });
  }

  @override
  void dispose() {
    _rooms.dispose();
    _scroll.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool _isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= _wideBreakpoint;

  Future<void> _open(ChatRoom room) async {
    _rooms.markLocallyAsRead(room.id);
    if (_isWide(context)) {
      setState(() => _selected = room);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoomPage(
          room: room,
          rooms: _rooms,
          onLeft: () => Navigator.pop(context),
        ),
      ),
    );
    _rooms.markLocallyAsRead(room.id);
  }

  Future<void> _newChat() async {
    final room = await NewChatSheet.show(context);
    if (room != null && mounted) await _open(room);
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on SupabaseChatCoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${e.message}: ${e.cause ?? ''}')),
        );
      }
    }
  }

  Future<void> _roomMenu(ChatRoom room) async {
    unawaited(HapticFeedback.mediumImpact());
    final isGroup = room.type == ChatRoomType.group;
    final scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        void run(Future<void> Function() action) {
          Navigator.pop(sheetContext);
          _guard(action);
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  room.isPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                ),
                title: Text(room.isPinned ? 'Unpin' : 'Pin to top'),
                onTap: () =>
                    run(() => _rooms.pinRoom(room.id, pinned: !room.isPinned)),
              ),
              if (room.isMuted)
                ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: const Text('Unmute'),
                  onTap: () => run(() => _rooms.unmuteRoom(room.id)),
                )
              else ...[
                ListTile(
                  leading: const Icon(Icons.notifications_paused_outlined),
                  title: const Text('Mute for 1 hour'),
                  onTap: () => run(
                    () => _rooms.muteRoom(
                      room.id,
                      duration: const Duration(hours: 1),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.volume_off_outlined),
                  title: const Text('Mute forever'),
                  onTap: () => run(() => _rooms.muteRoom(room.id)),
                ),
              ],
              ListTile(
                leading: Icon(
                  isGroup ? Icons.logout_rounded : Icons.delete_outline_rounded,
                  color: scheme.error,
                ),
                title: Text(
                  isGroup ? 'Leave group' : 'Delete chat',
                  style: TextStyle(color: scheme.error),
                ),
                onTap: () => run(
                  () => isGroup
                      ? SupabaseChatCore.instance.leaveRoom(room.id)
                      : SupabaseChatCore.instance.deleteRoom(room.id),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    final me = SupabaseChatCore.instance.loggedUser;
    if (_searching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            setState(() => _searching = false);
            _searchController.clear();
            _rooms.search('');
          },
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          autofocus: true,
          onChanged: _rooms.search,
          decoration: const InputDecoration(
            hintText: 'Search',
            filled: false,
            border: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
      );
    }
    return AppBar(
      leading: Padding(
        padding: const EdgeInsets.all(8),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () async {
            await ProfileSheet.show(context);
            if (mounted) setState(() {});
          },
          child: me == null
              ? const Icon(Icons.menu_rounded)
              : UserAvatar.user(me, size: 36),
        ),
      ),
      title: ListenableBuilder(
        listenable: _rooms,
        builder: (context, _) => Row(
          spacing: 8,
          children: [
            const Text('Chats'),
            if (_rooms.isLoading && _rooms.rooms.isNotEmpty)
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Search',
          onPressed: () => setState(() => _searching = true),
          icon: const Icon(Icons.search_rounded),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _list(BuildContext context) => Scaffold(
    appBar: _appBar(context),
    body: ListenableBuilder(
      listenable: _rooms,
      builder: (context, _) {
        if (_rooms.rooms.isEmpty) {
          if (_rooms.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_rooms.error != null) {
            return EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Cannot load your chats',
              message: '${_rooms.error!.cause ?? _rooms.error}',
              action: FilledButton.tonal(
                onPressed: _rooms.refresh,
                child: const Text('Retry'),
              ),
            );
          }
          return EmptyState(
            icon: Icons.chat_bubble_outline_rounded,
            title: _rooms.filter.isEmpty ? 'No chats yet' : 'No results',
            message: _rooms.filter.isEmpty
                ? 'Tap the pencil to message someone or create a group.'
                : 'Try a different name.',
          );
        }
        return RefreshIndicator(
          onRefresh: _rooms.refresh,
          child: ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: _rooms.rooms.length + (_rooms.hasMore ? 1 : 0),
            separatorBuilder: (_, _) => const Divider(indent: 76),
            itemBuilder: (context, index) {
              if (index >= _rooms.rooms.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final room = _rooms.rooms[index];
              return RoomTile(
                room: room,
                currentUserId: _me,
                selected: _selected?.id == room.id,
                onTap: () => _open(room),
                onLongPress: () => _roomMenu(room),
              );
            },
          ),
        );
      },
    ),
    floatingActionButton: FloatingActionButton(
      tooltip: 'New message',
      onPressed: _newChat,
      child: const Icon(Icons.edit_rounded),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_isWide(context)) return _list(context);
    final selected = _selected;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 380, child: _list(context)),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const ChatWallpaper(
                    child: Center(
                      child: ServiceChip(
                        text: 'Select a chat to start messaging',
                      ),
                    ),
                  )
                : RoomPage(
                    key: ValueKey(selected.id),
                    room: selected,
                    rooms: _rooms,
                    embedded: true,
                    onLeft: () => setState(() => _selected = null),
                  ),
          ),
        ],
      ),
    );
  }
}
