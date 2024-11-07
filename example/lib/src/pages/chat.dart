import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.room,
  });

  final types.Room room;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  bool _isAttachmentUploading = false;
  late SupabaseChatController _chatController;
  final String bucket = 'chats_assets';

  @override
  void initState() {
    _chatController = SupabaseChatController(room: widget.room);
    super.initState();
  }

  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }

  void _handleAttachmentPressed() {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: SizedBox(
          height: 130,
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
                    children: [
                      Icon(Icons.image),
                      Text('Image'),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _handleFileSelection();
                  },
                  child: const Row(
                    children: [
                      Icon(Icons.attach_file),
                      Text('File'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleFileSelection() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result != null && result.files.single.bytes != null) {
      _setAttachmentUploading(true);

      try {
        final bytes = result.files.single.bytes;
        final name = result.files.single.name;
        final mimeType = lookupMimeType(name, headerBytes: bytes);
        final path = '${widget.room.id}/${const Uuid().v1()}-$name';
        await Supabase.instance.client.storage.from(bucket).uploadBinary(
              path,
              bytes!,
              fileOptions: FileOptions(contentType: mimeType),
            );
        final url = SupabaseChatCore.getAssetUrl(bucket, path);
        final message = types.PartialFile(
          mimeType: mimeType,
          name: name,
          size: result.files.single.size,
          uri: url,
        );

        await SupabaseChatCore.instance.sendMessage(message, widget.room.id);
        _setAttachmentUploading(false);
      } finally {
        _setAttachmentUploading(false);
      }
    }
  }

  void _handleImageSelection() async {
    final result = await ImagePicker().pickImage(
      imageQuality: 70,
      maxWidth: 1440,
      source: ImageSource.gallery,
    );
    if (result != null) {
      _setAttachmentUploading(true);
      final bytes = await result.readAsBytes();
      final size = bytes.length;
      final image = await decodeImageFromList(bytes);
      final name = result.name;
      final mimeType = lookupMimeType(name, headerBytes: bytes);
      try {
        final path = '${widget.room.id}/${const Uuid().v1()}-$name';
        await Supabase.instance.client.storage.from(bucket).uploadBinary(
              path,
              bytes,
              fileOptions: FileOptions(contentType: mimeType),
            );
        final url = SupabaseChatCore.getAssetUrl(bucket, path);
        final message = types.PartialImage(
          height: image.height.toDouble(),
          name: name,
          size: size,
          uri: url,
          width: image.width.toDouble(),
        );
        await SupabaseChatCore.instance.sendMessage(
          message,
          widget.room.id,
        );
        _setAttachmentUploading(false);
      } finally {
        _setAttachmentUploading(false);
      }
    }
  }

  void _handleMessageTap(BuildContext _, types.Message message) async {
    if (message is types.FileMessage) {
      final client = http.Client();
      final request = await client.get(
        Uri.parse(message.uri),
        headers: SupabaseChatCore.instance.httpSupabaseHeaders,
      );
      final result = await FileSaver.instance.saveFile(
        name: message.uri.split('/').last,
        bytes: request.bodyBytes,
      );
      await OpenFilex.open(result);
    }
  }

  Future<void> _handlePreviewDataFetched(
    types.TextMessage message,
    types.PreviewData previewData,
  ) async {
    final updatedMessage = message.copyWith(previewData: previewData);

    await SupabaseChatCore.instance
        .updateMessage(updatedMessage, widget.room.id);
  }

  Future<void> _handleSendPressed(types.PartialText message) async {
    await _chatController.endTyping();
    await SupabaseChatCore.instance.sendMessage(
      message,
      widget.room.id,
    );
  }

  void _setAttachmentUploading(bool uploading) {
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
        body: StreamBuilder<List<types.Message>>(
          initialData: const [],
          stream: _chatController.messages,
          builder: (context, messages) => StreamBuilder<List<types.User>>(
            initialData: const [],
            stream: _chatController.typingUsers,
            builder: (context, users) => Chat(
              showUserNames: true,
              showUserAvatars: true,
              theme: const DefaultChatTheme(
                messageMaxWidth: 600,
              ),
              typingIndicatorOptions: TypingIndicatorOptions(
                typingUsers: users.data ?? [],
              ),
              isAttachmentUploading: _isAttachmentUploading,
              messages: messages.data ?? [],
              onAttachmentPressed: _handleAttachmentPressed,
              onMessageTap: _handleMessageTap,
              onPreviewDataFetched: _handlePreviewDataFetched,
              onSendPressed: _handleSendPressed,
              user: types.User(
                id: SupabaseChatCore.instance.loggedSupabaseUser!.id,
              ),
              imageHeaders: SupabaseChatCore.instance.httpSupabaseHeaders,
              onMessageVisibilityChanged: (message, visible) async {
                if (message.status != types.Status.seen &&
                    message.author.id !=
                        SupabaseChatCore.instance.loggedSupabaseUser!.id) {
                  await SupabaseChatCore.instance.updateMessage(
                    message.copyWith(status: types.Status.seen),
                    widget.room.id,
                  );
                }
              },
              onEndReached: _chatController.loadPreviousMessages,
              inputOptions: InputOptions(
                enabled: true,
                onTextChanged: (text) => _chatController.onTyping(),
              ),
            ),
          ),
        ),
      );
}
