import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../widgets/user_avatar.dart';
import 'new_chat_sheet.dart';

/// Group details: name, members and their roles. Admins rename the group,
/// add/remove members and promote/demote admins; everyone can leave.
/// Pops `true` when the user left or deleted the group.
class RoomInfoPage extends StatefulWidget {
  const RoomInfoPage({super.key, required this.room});

  final ChatRoom room;

  @override
  State<RoomInfoPage> createState() => _RoomInfoPageState();
}

class _RoomInfoPageState extends State<RoomInfoPage> {
  final _chat = SupabaseChatCore.instance;
  late ChatRoom _room = widget.room;
  late final StreamSubscription<ChatRoom> _subscription;

  String get _me => _chat.loggedUserId!;

  bool get _isAdmin => _room.roleOf(_me) == ChatRoomRole.admin;

  @override
  void initState() {
    super.initState();
    _subscription = _chat
        .room(_room.id)
        .listen(
          (room) {
            if (mounted) setState(() => _room = room);
          },
          onError: (Object e) {
            if (e is SupabaseChatCoreException) _showError(e);
          },
          onDone: () {
            if (mounted) Navigator.of(context).pop(true);
          },
        );
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  void _showError(SupabaseChatCoreException e) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${e.message}: ${e.cause ?? ''}')));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on SupabaseChatCoreException catch (e) {
      _showError(e);
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _room.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
    if (name == null || name.isEmpty) return;
    await _guard(() => _chat.updateRoom(_room.copyWith(name: name)));
  }

  Future<void> _addMembers() async {
    final users = await NewChatSheet.pickMembers(
      context,
      excludeUserIds: _room.users.map((u) => u.id).toSet(),
    );
    if (users == null || users.isEmpty) return;
    await _guard(
      () => _chat.addMembers(_room.id, users.map((u) => u.id).toList()),
    );
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _memberActions(ChatUser user) async {
    final isAdmin = user.role == ChatRoomRole.admin;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                isAdmin
                    ? Icons.remove_moderator_outlined
                    : Icons.shield_outlined,
              ),
              title: Text(isAdmin ? 'Remove admin rights' : 'Make admin'),
              onTap: () {
                Navigator.pop(sheetContext);
                _guard(
                  () => _chat.setMemberRole(
                    _room.id,
                    user.id,
                    isAdmin ? null : ChatRoomRole.admin,
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.person_remove_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Remove from group',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _guard(() => _chat.removeMember(_room.id, user.id));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _leave() async {
    if (!await _confirm(
      'Leave group?',
      "You won't receive messages from this group anymore.",
      'Leave',
    )) {
      return;
    }
    await _guard(() => _chat.leaveRoom(_room.id));
  }

  Future<void> _delete() async {
    if (!await _confirm(
      'Delete group?',
      'The group and all its messages are deleted for everyone.',
      'Delete',
    )) {
      return;
    }
    await _guard(() => _chat.deleteRoom(_room.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final members = [..._room.users]
      ..sort((a, b) {
        if (a.id == _me) return -1;
        if (b.id == _me) return 1;
        final byRole = (a.role == ChatRoomRole.admin ? 0 : 1).compareTo(
          b.role == ChatRoomRole.admin ? 0 : 1,
        );
        return byRole != 0 ? byRole : a.fullName.compareTo(b.fullName);
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Group info')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SizedBox(height: 8),
          Center(child: UserAvatar.room(_room, _me, size: 104)),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _room.name ?? 'Group',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (_isAdmin)
                IconButton(
                  tooltip: 'Rename',
                  onPressed: _rename,
                  icon: const Icon(Icons.edit_outlined),
                ),
            ],
          ),
          Text(
            '${_room.users.length} members',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  if (_isAdmin)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: scheme.primaryContainer,
                        child: Icon(
                          Icons.person_add_alt_1_outlined,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                      title: const Text('Add members'),
                      onTap: _addMembers,
                    ),
                  for (final user in members)
                    ListTile(
                      leading: UserAvatar.user(user, showOnlineStatus: true),
                      title: Text(
                        user.id == _me ? 'You' : user.fullName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      trailing: user.role == ChatRoomRole.admin
                          ? Chip(
                              label: const Text('Admin'),
                              visualDensity: VisualDensity.compact,
                              side: BorderSide.none,
                              backgroundColor: scheme.tertiaryContainer,
                            )
                          : null,
                      onTap: _isAdmin && user.id != _me
                          ? () => _memberActions(user)
                          : null,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.logout_rounded, color: scheme.error),
                    title: Text(
                      'Leave group',
                      style: TextStyle(color: scheme.error),
                    ),
                    onTap: _leave,
                  ),
                  if (_isAdmin)
                    ListTile(
                      leading: Icon(
                        Icons.delete_outline_rounded,
                        color: scheme.error,
                      ),
                      title: Text(
                        'Delete group',
                        style: TextStyle(color: scheme.error),
                      ),
                      onTap: _delete,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
