import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:flyer_chat_file_message/flyer_chat_file_message.dart';
import 'package:flyer_chat_image_message/flyer_chat_image_message.dart';
import 'package:flyer_chat_text_message/flyer_chat_text_message.dart';
import 'package:uuid/uuid.dart';

import '../theme/app_theme.dart';
import '../utils/attachments.dart';
import '../utils/format.dart';
import '../widgets/audio_message_bubble.dart';
import '../widgets/chat_wallpaper.dart';
import '../widgets/message_actions_sheet.dart';
import '../widgets/pinned_banner.dart';
import '../widgets/reactions_row.dart';
import '../widgets/reply_quote.dart';
import '../widgets/swipe_to_reply.dart';
import '../widgets/user_avatar.dart';
import 'image_viewer_page.dart';
import 'message_search_page.dart';
import 'room_info_page.dart';

/// A conversation, Telegram style.
class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    required this.room,
    this.rooms,
    this.embedded = false,
    this.onLeft,
  });

  final ChatRoom room;

  /// Rooms list controller, to apply pin/mute changes to the list at once.
  final SupabaseChatRoomsController? rooms;

  /// Shown inside the wide layout's right pane (no back button).
  final bool embedded;

  /// Called after the user left or deleted the room.
  final VoidCallback? onLeft;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final _chat = SupabaseChatCore.instance;
  final _text = TextEditingController();
  final _composerFocus = FocusNode();
  late final SupabaseChatController _controller;
  late final StreamSubscription<ChatRoom> _roomSubscription;
  late ChatRoom _room = widget.room;
  core.Message? _replyTo;
  bool _uploading = false;

  String get _me => _chat.loggedUserId!;

  bool get _isGroup => _room.type == ChatRoomType.group;

  /// Direct rooms: both members. Groups: admins.
  bool get _canModerate => !_isGroup || _room.roleOf(_me) == ChatRoomRole.admin;

  @override
  void initState() {
    super.initState();
    _controller = SupabaseChatController(room: widget.room, onError: _onError);
    _text.addListener(() {
      if (_text.text.isNotEmpty) _controller.onTyping();
    });
    _roomSubscription = _chat
        .room(widget.room.id)
        .listen(
          (room) {
            if (mounted) setState(() => _room = room);
          },
          onError: (Object e) {
            if (e is SupabaseChatCoreException) _onError(e);
          },
          onDone: () {
            // Room deleted, or we were removed from it.
            if (mounted) widget.onLeft?.call();
          },
        );
  }

  @override
  void dispose() {
    _roomSubscription.cancel();
    _controller.dispose();
    _text.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _onError(SupabaseChatCoreException error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${error.message}: ${error.cause ?? ''}')),
    );
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on SupabaseChatCoreException catch (e) {
      _onError(e);
    }
  }

  Future<core.User?> _resolveUser(String id) async {
    final member = _room.member(id);
    if (member != null) return member.toCoreUser();
    final user = await _chat.user(uid: id);
    return user?.toCoreUser();
  }

  void _startReply(core.Message message) {
    unawaited(HapticFeedback.lightImpact());
    setState(() => _replyTo = message);
    _composerFocus.requestFocus();
  }

  void _send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final replyTo = _replyTo?.id;
    setState(() => _replyTo = null);
    _guard(
      () => _controller.sendMessage(
        core.Message.text(
          id: const Uuid().v7(),
          authorId: _me,
          text: trimmed,
          replyToMessageId: replyTo,
        ),
      ),
    );
  }

  Future<void> _attach() async {
    final kind = await showModalBottomSheet<AttachmentKind>(
      context: context,
      builder: (_) => const AttachmentPickerSheet(),
    );
    if (kind == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final message = await pickAttachment(
        context,
        kind,
        room: _room,
        authorId: _me,
      );
      if (message != null) await _controller.sendMessage(message);
    } on SupabaseChatCoreException catch (e) {
      _onError(e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _jumpTo(core.Message message) async {
    final found = await _controller.jumpToMessage(message.id);
    if (!found && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That message is too far back')),
      );
    }
  }

  Future<void> _onMessageTap(
    BuildContext context,
    core.Message message, {
    required int index,
    required TapUpDetails details,
  }) async {
    switch (message) {
      case core.ImageMessage():
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (_) => ImageViewerPage(message: message),
          ),
        );
      case core.FileMessage():
        await _guard(() => openFileMessage(message));
      default:
        break;
    }
  }

  Future<void> _onMessageLongPress(
    BuildContext context,
    core.Message message, {
    required int index,
    required LongPressStartDetails details,
  }) => _showActions(context, message);

  /// Desktop/web: right click opens the same menu as a long press.
  void _onMessageSecondaryTap(
    BuildContext context,
    core.Message message, {
    required int index,
    TapUpDetails? details,
  }) => unawaited(_showActions(context, message));

  Future<void> _showActions(BuildContext context, core.Message message) async {
    unawaited(HapticFeedback.mediumImpact());
    final mine = message.authorId == _me;
    final action = await MessageActionsSheet.show(
      context,
      message: message,
      canEdit: mine && message is core.TextMessage,
      canDelete: mine || _room.roleOf(_me) == ChatRoomRole.admin,
      canPin: _canModerate,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case MessageReact(:final emoji):
        await _guard(() => _controller.toggleReaction(message.id, emoji));
      case MessageReply():
        _startReply(message);
      case MessagePin(:final pinned):
        await _guard(() => _controller.setPinned(message, pinned: pinned));
      case MessageCopy():
        if (message is core.TextMessage) {
          await Clipboard.setData(ClipboardData(text: message.text));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copied to clipboard')),
            );
          }
        }
      case MessageEdit():
        final text = await _editDialog((message as core.TextMessage).text);
        if (text != null && text.trim().isNotEmpty && text != message.text) {
          await _guard(() => _controller.editTextMessage(message, text.trim()));
        }
      case MessageDelete():
        await _guard(() async {
          await _controller.deleteMessage(message.id);
        });
      case MessageRetry():
        await _guard(() => _controller.retryMessage(message));
    }
  }

  Future<String?> _editDialog(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _openInfo() async {
    final left = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => RoomInfoPage(room: _room)));
    if (left == true && mounted) widget.onLeft?.call();
  }

  Future<void> _search() async {
    final message = await Navigator.of(context).push<core.Message>(
      MaterialPageRoute(builder: (_) => MessageSearchPage(room: _room)),
    );
    if (message != null && mounted) await _jumpTo(message);
  }

  Future<void> _toggleMute() => _guard(() async {
    final rooms = widget.rooms;
    if (_room.isMuted) {
      await (rooms?.unmuteRoom(_room.id) ?? _chat.unmuteRoom(_room.id));
    } else {
      await (rooms?.muteRoom(_room.id) ?? _chat.muteRoom(_room.id));
    }
    final room = await _chat.getRoom(_room.id);
    if (room != null && mounted) setState(() => _room = room);
  });

  Future<void> _deleteDirect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: const Text('Every message will be deleted for both of you.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size(0, 40),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _guard(() => _chat.deleteRoom(_room.id));
  }

  Widget _subtitle(ThemeData theme) {
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return StreamBuilder<List<ChatUser>>(
      stream: _controller.typingUsers,
      builder: (context, snapshot) {
        final typing = snapshot.data ?? const [];
        if (typing.isNotEmpty) {
          return Row(
            spacing: 6,
            children: [
              IsTypingIndicator(color: theme.colorScheme.primary, size: 4),
              Flexible(
                child: Text(
                  _isGroup
                      ? '${typing.map((u) => u.firstName ?? 'Someone').join(', ')} typing'
                      : 'typing',
                  overflow: TextOverflow.ellipsis,
                  style: style?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          );
        }
        if (_isGroup) {
          return Text('${_room.users.length} members', style: style);
        }
        final other = _room.otherUser(_me);
        if (other == null) return const SizedBox.shrink();
        return UserOnlineStatusWidget(
          uid: other.id,
          builder: (status) => Text(
            status == UserOnlineStatus.online
                ? 'online'
                : formatLastSeen(other.lastSeen),
            style: status == UserOnlineStatus.online
                ? style?.copyWith(color: theme.colorScheme.primary)
                : style,
          ),
        );
      },
    );
  }

  /// Telegram draws the "tail" on the last bubble of a group: square the
  /// corner on the sender side there, round everything else.
  BorderRadius _bubbleRadius(bool isSentByMe, core.MessageGroupStatus? group) {
    const big = Radius.circular(16);
    const small = Radius.circular(4);
    final last = group?.isLast ?? true;
    return BorderRadius.only(
      topLeft: big,
      topRight: big,
      bottomLeft: !isSentByMe && last ? small : big,
      bottomRight: isSentByMe && last ? small : big,
    );
  }

  Widget? _dateHeader(int index, core.Message message) {
    final messages = _controller.messages;
    final date = message.createdAt?.toLocal();
    if (date == null) return null;
    if (index > 0 && index - 1 < messages.length) {
      final previous = messages[index - 1].createdAt?.toLocal();
      if (previous != null &&
          previous.year == date.year &&
          previous.month == date.month &&
          previous.day == date.day) {
        return null;
      }
    }
    return ServiceChip(text: formatDayHeader(context, date));
  }

  Widget _messageWrapper(
    BuildContext context,
    core.Message message,
    int index,
    Animation<double> animation,
    Widget child, {
    bool? isRemoved,
    required bool isSentByMe,
    core.MessageGroupStatus? groupStatus,
  }) {
    final showAuthor = _isGroup && !isSentByMe;
    final firstInGroup = groupStatus?.isFirst ?? true;
    final lastInGroup = groupStatus?.isLast ?? true;
    final author = _room.member(message.authorId);
    final scheme = Theme.of(context).colorScheme;
    final dateHeader = _dateHeader(index, message);
    final authorHeader = showAuthor && firstInGroup && author != null
        ? Padding(
            padding: const EdgeInsets.only(left: 52, bottom: 2, top: 4),
            child: Text(
              author.fullName,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: avatarColor(author.id, scheme),
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        : null;
    final edited = message.metadata?['edited'] == true;
    return ChatMessage(
      message: message,
      index: index,
      animation: animation,
      isRemoved: isRemoved,
      groupStatus: groupStatus,
      leadingWidget: showAuthor
          ? Padding(
              padding: const EdgeInsets.only(right: 8),
              child: lastInGroup && author != null
                  ? UserAvatar.user(author, size: 34)
                  : const SizedBox(width: 34),
            )
          : null,
      headerWidget: dateHeader == null && authorHeader == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [?dateHeader, ?authorHeader],
            ),
      bottomWidget: Column(
        crossAxisAlignment: isSentByMe
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          ReactionsRow(
            message: message,
            currentUserId: _me,
            alignEnd: isSentByMe,
            onToggle: (emoji) =>
                _guard(() => _controller.toggleReaction(message.id, emoji)),
          ),
          if (edited)
            Padding(
              padding: const EdgeInsets.only(top: 1, left: 4, right: 4),
              child: Text(
                'edited',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: ChatPalette.of(context).onServiceChip,
                  shadows: const [Shadow(blurRadius: 4, color: Colors.black26)],
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
      child: message.status == core.MessageStatus.error
          ? child
          : SwipeToReply(onReply: () => _startReply(message), child: child),
    );
  }

  Widget? _quoteFor(core.Message message, Color onBubble) {
    final id = message.replyToMessageId;
    if (id == null) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ReplyQuote(
        key: ValueKey('quote-$id'),
        controller: _controller,
        room: _room,
        messageId: id,
        onSurface: onBubble,
        onTap: () async {
          final quoted = await _controller.resolveMessage(id);
          if (quoted != null) await _jumpTo(quoted);
        },
      ),
    );
  }

  Widget _composerTop(ThemeData theme) {
    final reply = _replyTo;
    final palette = ChatPalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          child: reply == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                  child: Row(
                    spacing: 8,
                    children: [
                      Icon(Icons.reply_rounded, color: palette.accent),
                      Expanded(
                        child: QuoteBlock(
                          color: palette.accent,
                          title:
                              'Reply to ${_room.member(reply.authorId)?.fullName ?? 'message'}',
                          text: messagePreview(reply).text,
                          textColor: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cancel reply',
                        onPressed: () => setState(() => _replyTo = null),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = ChatPalette.of(context);
    final chatTheme = AppTheme.chatTheme(theme);
    final headers = _chat.httpSupabaseHeaders;
    TextStyle metaStyle(bool mine) => theme.textTheme.labelSmall!.copyWith(
      color: mine ? palette.sentMeta : palette.receivedMeta,
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _isGroup ? _openInfo : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              spacing: 12,
              children: [
                UserAvatar.room(_room, _me, size: 40),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        spacing: 4,
                        children: [
                          Flexible(
                            child: Text(
                              _room.name ?? 'Chat',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (_room.isMuted)
                            Icon(
                              Icons.volume_off_rounded,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                        ],
                      ),
                      _subtitle(theme),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: _search,
            icon: const Icon(Icons.search_rounded),
          ),
          PopupMenuButton<void>(
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: _toggleMute,
                child: ListTile(
                  leading: Icon(
                    _room.isMuted
                        ? Icons.volume_up_outlined
                        : Icons.volume_off_outlined,
                  ),
                  title: Text(_room.isMuted ? 'Unmute' : 'Mute'),
                ),
              ),
              if (_isGroup)
                PopupMenuItem(
                  onTap: _openInfo,
                  child: const ListTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text('Group info'),
                  ),
                )
              else
                PopupMenuItem(
                  onTap: _deleteDirect,
                  child: ListTile(
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: scheme.error,
                    ),
                    title: Text(
                      'Delete chat',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                ),
            ],
          ),
        ],
        bottom: _uploading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: Column(
        children: [
          PinnedBanner(
            controller: _controller,
            onJump: _jumpTo,
            onUnpin: _canModerate
                ? (m) => _guard(() => _controller.setPinned(m, pinned: false))
                : null,
          ),
          Expanded(
            child: ChatWallpaper(
              child: Chat(
                currentUserId: _me,
                resolveUser: _resolveUser,
                chatController: _controller,
                theme: chatTheme,
                backgroundColor: Colors.transparent,
                onMessageSend: _send,
                onAttachmentTap: _uploading ? null : _attach,
                onMessageTap: _onMessageTap,
                onMessageLongPress: _onMessageLongPress,
                onMessageSecondaryTap: _onMessageSecondaryTap,
                builders: core.Builders(
                  chatAnimatedListBuilder: (context, itemBuilder) =>
                      ChatAnimatedList(
                        itemBuilder: itemBuilder,
                        onEndReached: _controller.loadPreviousMessages,
                      ),
                  chatMessageBuilder: _messageWrapper,
                  emptyChatListBuilder: (context) => Center(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: palette.serviceChip,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          const Text('👋', style: TextStyle(fontSize: 48)),
                          Text(
                            'No messages here yet',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: palette.onServiceChip,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TextButton(
                            onPressed: () => _send('👋'),
                            child: Text(
                              'Say hi',
                              style: TextStyle(color: palette.onServiceChip),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  textMessageBuilder:
                      (
                        context,
                        message,
                        index, {
                        required isSentByMe,
                        groupStatus,
                      }) => FlyerChatTextMessage(
                        message: message,
                        index: index,
                        showStatus: isSentByMe,
                        borderRadius: _bubbleRadius(isSentByMe, groupStatus),
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                        sentBackgroundColor: palette.sentBubble,
                        receivedBackgroundColor: palette.receivedBubble,
                        sentTextStyle: theme.textTheme.bodyLarge?.copyWith(
                          color: palette.onSentBubble,
                        ),
                        receivedTextStyle: theme.textTheme.bodyLarge?.copyWith(
                          color: palette.onReceivedBubble,
                        ),
                        sentLinksColor: palette.accent,
                        receivedLinksColor: palette.accent,
                        timeStyle: metaStyle(isSentByMe),
                        timeAndStatusPosition:
                            core.TimeAndStatusPosition.inline,
                        topWidget: _quoteFor(
                          message,
                          isSentByMe
                              ? palette.onSentBubble
                              : palette.onReceivedBubble,
                        ),
                      ),
                  imageMessageBuilder:
                      (
                        context,
                        message,
                        index, {
                        required isSentByMe,
                        groupStatus,
                      }) => Hero(
                        tag: message.id,
                        child: FlyerChatImageMessage(
                          message: message,
                          index: index,
                          headers: headers,
                          showStatus: isSentByMe,
                          borderRadius: _bubbleRadius(isSentByMe, groupStatus),
                          timeBackground: Colors.black45,
                          timeStyle: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                  fileMessageBuilder:
                      (
                        context,
                        message,
                        index, {
                        required isSentByMe,
                        groupStatus,
                      }) =>
                          FlyerChatFileMessage(message: message, index: index),
                  audioMessageBuilder:
                      (
                        context,
                        message,
                        index, {
                        required isSentByMe,
                        groupStatus,
                      }) => AudioMessageBubble(
                        message: message,
                        isSentByMe: isSentByMe,
                        footer: Text(
                          formatTime(message.createdAt ?? DateTime.now()),
                          style: metaStyle(isSentByMe),
                        ),
                      ),
                  unsupportedMessageBuilder:
                      (
                        context,
                        message,
                        index, {
                        required isSentByMe,
                        groupStatus,
                      }) => Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: palette.receivedBubble,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          'Unsupported message',
                          style: TextStyle(color: palette.receivedMeta),
                        ),
                      ),
                  composerBuilder: (context) => Composer(
                    textEditingController: _text,
                    focusNode: _composerFocus,
                    hintText: 'Message',
                    sendOnEnter: kIsWeb,
                    backgroundColor: scheme.surface,
                    inputFillColor: scheme.surface,
                    attachmentIconColor: scheme.onSurfaceVariant,
                    sendIconColor: scheme.primary,
                    topWidget: _composerTop(theme),
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
