import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A minimal audio message bubble (play/pause + duration).
///
/// There's no usable `flyer_chat_audio_message` widget to build on yet (the
/// published package is an empty placeholder), so this is a small custom
/// builder instead — wire it via `Builders(audioMessageBuilder: ...)`.
class AudioMessageBubble extends StatefulWidget {
  const AudioMessageBubble({
    super.key,
    required this.message,
    required this.isSentByMe,
  });

  final core.AudioMessage message;
  final bool isSentByMe;

  @override
  State<AudioMessageBubble> createState() => _AudioMessageBubbleState();
}

class _AudioMessageBubbleState extends State<AudioMessageBubble> {
  final AudioPlayer _player = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  String? _localPath;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playerState = state);
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_playerState == PlayerState.playing) {
      await _player.pause();
      return;
    }
    if (_playerState == PlayerState.paused && _localPath != null) {
      await _player.resume();
      return;
    }

    setState(() => _isLoading = true);
    try {
      // Playing the network URL directly would need auth headers audioplayers
      // can't attach on every platform, so fetch the (authenticated) bytes
      // ourselves first, same as FileMessage download elsewhere in this app.
      _localPath ??= await _download();
      await _player.play(DeviceFileSource(_localPath!));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String> _download() async {
    final response = await http.get(
      Uri.parse(widget.message.source),
      headers: SupabaseChatCore.instance.httpSupabaseHeaders,
    );
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${widget.message.id}.m4a');
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = _playerState == PlayerState.playing;
    final foreground = widget.isSentByMe ? Colors.white : Colors.black87;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: _isLoading
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: foreground,
                    ),
                  )
                : IconButton(
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                    ),
                    color: foreground,
                    onPressed: _togglePlayback,
                  ),
          ),
          Text(
            _formatDuration(widget.message.duration),
            style: TextStyle(color: foreground),
          ),
        ],
      ),
    );
  }
}
