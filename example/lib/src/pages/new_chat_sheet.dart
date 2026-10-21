import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../widgets/user_avatar.dart';

/// Picks people to talk to: tap someone for a direct chat, or switch to
/// "New group", select several people and name the group. Pops the
/// resulting [ChatRoom].
///
/// With [excludeUserIds] it works as a member picker for an existing group
/// instead, popping the selected users as a `List<ChatUser>`.
class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key, this.excludeUserIds});

  final Set<String>? excludeUserIds;

  /// Opens the sheet and returns the created/opened room, if any.
  static Future<ChatRoom?> show(BuildContext context) =>
      showModalBottomSheet<ChatRoom>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const NewChatSheet(),
      );

  /// Opens the sheet as a member picker.
  static Future<List<ChatUser>?> pickMembers(
    BuildContext context, {
    required Set<String> excludeUserIds,
  }) => showModalBottomSheet<List<ChatUser>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => NewChatSheet(excludeUserIds: excludeUserIds),
  );

  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  static const _pageSize = 30;
  final _scroll = ScrollController();
  final _groupName = TextEditingController();
  final List<ChatUser> _users = [];
  final Map<String, ChatUser> _selected = {};
  Timer? _debounce;
  String _filter = '';
  bool _loading = false;
  bool _hasMore = true;
  bool _creating = false;
  late bool _groupMode = widget.excludeUserIds != null;
  int _generation = 0;

  bool get _pickingMembers => widget.excludeUserIds != null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300) _load();
    });
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _groupName.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || !_hasMore)) return;
    final generation = reset ? ++_generation : _generation;
    setState(() {
      _loading = true;
      if (reset) {
        _users.clear();
        _hasMore = true;
      }
    });
    try {
      final page = await SupabaseChatCore.instance.users(
        filter: _filter,
        offset: _users.length,
        limit: _pageSize,
        excludeLoggedUser: true,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _users.addAll(
          page.where((u) => !(widget.excludeUserIds?.contains(u.id) ?? false)),
        );
        _hasMore = page.length >= _pageSize;
      });
    } on SupabaseChatCoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot load users: ${e.cause ?? e}')),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _filter = value;
      _load(reset: true);
    });
  }

  Future<void> _openDirect(ChatUser user) async {
    setState(() => _creating = true);
    try {
      final room = await SupabaseChatCore.instance.createRoom(user);
      if (mounted) Navigator.of(context).pop(room);
    } on SupabaseChatCoreException catch (e) {
      _showError(e);
    }
  }

  Future<void> _createGroup() async {
    final name = _groupName.text.trim();
    if (name.isEmpty || _selected.isEmpty) return;
    setState(() => _creating = true);
    try {
      final room = await SupabaseChatCore.instance.createGroupRoom(
        name: name,
        users: _selected.values.toList(),
      );
      if (mounted) Navigator.of(context).pop(room);
    } on SupabaseChatCoreException catch (e) {
      _showError(e);
    }
  }

  void _showError(SupabaseChatCoreException e) {
    if (!mounted) return;
    setState(() => _creating = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Something went wrong: ${e.cause ?? e}')),
    );
  }

  void _toggle(ChatUser user) => setState(() {
    if (_selected.remove(user.id) == null) _selected[user.id] = user;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canSubmit = _pickingMembers
        ? _selected.isNotEmpty
        : _selected.isNotEmpty && _groupName.text.trim().isNotEmpty;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .9,
      minChildSize: .5,
      maxChildSize: 1,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _pickingMembers
                        ? 'Add members'
                        : _groupMode
                        ? 'New group'
                        : 'New chat',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (!_pickingMembers)
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _groupMode = !_groupMode;
                      _selected.clear();
                    }),
                    icon: Icon(
                      _groupMode
                          ? Icons.person_outline
                          : Icons.group_add_outlined,
                    ),
                    label: Text(_groupMode ? 'Direct chat' : 'New group'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              spacing: 10,
              children: [
                if (_groupMode && !_pickingMembers)
                  TextField(
                    controller: _groupName,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Group name',
                      prefixIcon: Icon(Icons.edit_outlined),
                    ),
                  ),
                TextField(
                  onChanged: _onSearch,
                  decoration: const InputDecoration(
                    hintText: 'Search people',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ],
            ),
          ),
          if (_selected.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                children: [
                  for (final user in _selected.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: InputChip(
                        avatar: UserAvatar.user(user, size: 24),
                        label: Text(user.firstName ?? user.fullName),
                        onDeleted: () => _toggle(user),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _users.isEmpty && !_loading
                ? Center(
                    child: Text(
                      'Nobody found',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _users.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _users.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final user = _users[index];
                      final selected = _selected.containsKey(user.id);
                      return ListTile(
                        enabled: !_creating,
                        leading: UserAvatar.user(user, showOnlineStatus: true),
                        title: Text(
                          user.fullName.isEmpty
                              ? 'Unnamed user'
                              : user.fullName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        trailing: _groupMode
                            ? Checkbox(
                                value: selected,
                                onChanged: (_) => _toggle(user),
                              )
                            : const Icon(Icons.chevron_right_rounded),
                        onTap: () =>
                            _groupMode ? _toggle(user) : _openDirect(user),
                      );
                    },
                  ),
          ),
          if (_groupMode)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  onPressed: !canSubmit || _creating
                      ? null
                      : _pickingMembers
                      ? () =>
                            Navigator.of(context).pop(_selected.values.toList())
                      : _createGroup,
                  icon: _creating
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _pickingMembers
                              ? Icons.person_add_alt_1_outlined
                              : Icons.check_rounded,
                        ),
                  label: Text(
                    _pickingMembers
                        ? 'Add ${_selected.length} member${_selected.length == 1 ? '' : 's'}'
                        : 'Create group (${_selected.length})',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
