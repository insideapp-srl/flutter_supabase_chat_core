import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:flyer_chat_file_message/flyer_chat_file_message.dart';
import 'package:flyer_chat_image_message/flyer_chat_image_message.dart';
import 'package:flyer_chat_text_message/flyer_chat_text_message.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../widgets/audio_message_bubble.dart';

class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.room});

  final ChatRoom room;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  bool _isAttachmentUploading = false;
  late final SupabaseChatController _chatController;
  final TextEditingController _textEditingController = TextEditingController();
  final AudioRecorder _audioRecorder = AudioRecorder();

  String get _currentUserId => SupabaseChatCore.instance.loggedSupabaseUser!.id;

  @override
  void initState() {
    super.initState();
    _chatController = SupabaseChatController(room: widget.room);
    _textEditingController.addListener(() {
      if (_textEditingController.text.isNotEmpty) {
        _chatController.onTyping();
      }
    });
  }

  @override
  void dispose() {
    _textEditingController.dispose();
    _chatController.dispose();
    _audioRecorder.dispose();
    super.dispose();
  }

  /// Resolves a [core.User] for `Chat.resolveUser`. Room members are already
  /// known locally; anyone else (e.g. a user who left the room) is fetched
  /// from Supabase.
  Future<core.User?> _resolveUser(String id) async {
    for (final user in widget.room.users) {
      if (user.id == id) return user.toCoreUser();
    }
    final fetched = await SupabaseChatCore.instance.user(uid: id);
    return fetched?.toCoreUser();
  }

  void _handleAttachmentTap() {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: SizedBox(
          height: 170,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _handleImageSelection();
                  },
                  child: const Row(
                    children: [Icon(Icons.image), Text('Image')],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _handleFileSelection();
                  },
                  child: const Row(
                    children: [Icon(Icons.attach_file), Text('File')],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _handleAudioRecording();
                  },
                  child: const Row(children: [Icon(Icons.mic), Text('Audio')]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleFileSelection() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;

    _setAttachmentUploading(true);
    try {
      final name = file.name;
      final bytes = await file.readAsBytes();
      final size = await file.length();
      final uploadResult = await SupabaseChatCore.instance.uploadAsset(
        widget.room,
        name,
        bytes,
      );
      final message = core.Message.file(
        id: const Uuid().v7(),
        authorId: _currentUserId,
        source: uploadResult.url,
        name: name,
        size: size,
        mimeType: uploadResult.mimeType,
      );
      await _chatController.sendMessage(message);
    } finally {
      _setAttachmentUploading(false);
    }
  }

  Future<void> _handleImageSelection() async {
    final result = await ImagePicker().pickImage(
      imageQuality: 70,
      maxWidth: 1440,
      source: ImageSource.gallery,
    );
    if (result == null) return;

    _setAttachmentUploading(true);
    try {
      final bytes = await result.readAsBytes();
      final size = bytes.length;
      final image = await decodeImageFromList(bytes);
      final name = result.name;
      final uploadResult = await SupabaseChatCore.instance.uploadAsset(
        widget.room,
        name,
        bytes,
      );
      final message = core.Message.image(
        id: const Uuid().v7(),
        authorId: _currentUserId,
        source: uploadResult.url,
        height: image.height.toDouble(),
        width: image.width.toDouble(),
        size: size,
      );
      await _chatController.sendMessage(message);
    } finally {
      _setAttachmentUploading(false);
    }
  }

  Future<void> _handleAudioRecording() async {
    if (!await _audioRecorder.hasPermission()) return;

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${const Uuid().v7()}.m4a';
    await _audioRecorder.start(const RecordConfig(), path: path);

    if (!mounted) return;
    final duration = await showModalBottomSheet<Duration>(
      context: context,
      isDismissible: false,
      builder: (context) => const _AudioRecordingSheet(),
    );

    final recordedPath = await _audioRecorder.stop();
    if (recordedPath == null || duration == null) return;

    _setAttachmentUploading(true);
    try {
      final bytes = await File(recordedPath).readAsBytes();
      final uploadResult = await SupabaseChatCore.instance.uploadAsset(
        widget.room,
        '${const Uuid().v7()}.m4a',
        bytes,
      );
      final message = core.Message.audio(
        id: const Uuid().v7(),
        authorId: _currentUserId,
        source: uploadResult.url,
        duration: duration,
        size: bytes.length,
      );
      await _chatController.sendMessage(message);
    } finally {
      _setAttachmentUploading(false);
    }
  }

  Future<void> _handleMessageTap(
    BuildContext context,
    core.Message message, {
    required int index,
    required TapUpDetails details,
  }) async {
    if (message is core.FileMessage) {
      final client = http.Client();
      final request = await client.get(
        Uri.parse(message.source),
        headers: SupabaseChatCore.instance.httpSupabaseHeaders,
      );
      final result = await FileSaver.instance.saveFile(
        name: message.source.split('/').last,
        bytes: request.bodyBytes,
      );
      await OpenFilex.open(result);
    }
  }

  Future<void> _handleMessageLongPress(
    BuildContext context,
    core.Message message, {
    required int index,
    required LongPressStartDetails details,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmation of deletion'),
        content: const Text('Do you really want to delete this message?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _chatController.deleteMessage(message.id);
    }
  }

  void _handleMessageSend(String text) {
    _chatController.endTyping();
    final message = core.Message.text(
      id: const Uuid().v7(),
      authorId: _currentUserId,
      text: text,
    );
    _chatController.sendMessage(message);
  }

  void _setAttachmentUploading(bool uploading) {
    if (!mounted) return;
    setState(() {
      _isAttachmentUploading = uploading;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      systemOverlayStyle: SystemUiOverlayStyle.light,
      title: const Text('Chat'),
    ),
    body: Chat(
      currentUserId: _currentUserId,
      resolveUser: _resolveUser,
      chatController: _chatController,
      theme: core.ChatTheme.light(),
      onAttachmentTap: _isAttachmentUploading ? null : _handleAttachmentTap,
      onMessageTap: _handleMessageTap,
      onMessageLongPress: _handleMessageLongPress,
      onMessageSend: _handleMessageSend,
      builders: core.Builders(
        textMessageBuilder:
            (context, message, index, {required isSentByMe, groupStatus}) =>
                FlyerChatTextMessage(message: message, index: index),
        imageMessageBuilder:
            (context, message, index, {required isSentByMe, groupStatus}) =>
                FlyerChatImageMessage(
                  message: message,
                  index: index,
                  headers: SupabaseChatCore.instance.httpSupabaseHeaders,
                ),
        fileMessageBuilder:
            (context, message, index, {required isSentByMe, groupStatus}) =>
                FlyerChatFileMessage(message: message, index: index),
        audioMessageBuilder:
            (context, message, index, {required isSentByMe, groupStatus}) =>
                AudioMessageBubble(message: message, isSentByMe: isSentByMe),
        composerBuilder: (context) =>
            Composer(textEditingController: _textEditingController),
      ),
    ),
  );
}

/// Shown while recording: elapsed time plus cancel/send. Pops the recorded
/// [Duration] on send, or `null` on cancel.
class _AudioRecordingSheet extends StatefulWidget {
  const _AudioRecordingSheet();

  @override
  State<_AudioRecordingSheet> createState() => _AudioRecordingSheetState();
}

class _AudioRecordingSheetState extends State<_AudioRecordingSheet> {
  final Stopwatch _stopwatch = Stopwatch()..start();
  late final Timer _timer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted) setState(() => _elapsed = _stopwatch.elapsed);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic, size: 48, color: Colors.red),
          const SizedBox(height: 8),
          Text(
            _format(_elapsed),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(_stopwatch.elapsed),
                icon: const Icon(Icons.send),
                label: const Text('Send'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
