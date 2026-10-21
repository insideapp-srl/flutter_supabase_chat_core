import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:http/http.dart' as http;

import '../theme/app_theme.dart';
import '../utils/attachments.dart';
import '../utils/format.dart';

/// Telegram-style voice message: round play button, waveform that fills
/// as it plays (tap/drag it to seek), elapsed/total duration.
///
/// There's no usable `flyer_chat_audio_message` widget to build on yet (the
/// published package is an empty placeholder), so this is a small custom
/// builder instead — wired via `Builders(audioMessageBuilder: ...)`.
class AudioMessageBubble extends StatefulWidget {
  const AudioMessageBubble({
    super.key,
    required this.message,
    required this.isSentByMe,
    this.footer,
  });

  final core.AudioMessage message;
  final bool isSentByMe;

  /// Time/status line drawn under the waveform.
  final Widget? footer;

  @override
  State<AudioMessageBubble> createState() => _AudioMessageBubbleState();
}

class _AudioMessageBubbleState extends State<AudioMessageBubble> {
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Uint8List? _bytes;
  bool _loading = false;

  late final List<double> _bars = _resolveBars();

  List<double> _resolveBars() {
    final waveform = widget.message.waveform;
    if (waveform != null && waveform.isNotEmpty) return waveform;
    // No recorded waveform (e.g. uploaded file): a stable pseudo-random one.
    final random = math.Random(widget.message.id.hashCode);
    return [for (var i = 0; i < 40; i++) .2 + random.nextDouble() * .8];
  }

  @override
  void initState() {
    super.initState();
    _subscriptions
      ..add(
        _player.onPlayerStateChanged.listen((state) {
          if (mounted) setState(() => _state = state);
        }),
      )
      ..add(
        _player.onPositionChanged.listen((position) {
          if (mounted) setState(() => _position = position);
        }),
      )
      ..add(
        _player.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _position = Duration.zero);
        }),
      );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  Future<void> _ensureSource() async {
    if (_bytes != null) return;
    setState(() => _loading = true);
    try {
      // Playing the URL directly would need auth headers audioplayers can't
      // attach on every platform: fetch the (authenticated) bytes first.
      final response = await http.get(
        Uri.parse(widget.message.source),
        headers: SupabaseChatCore.instance.httpSupabaseHeaders,
      );
      if (response.statusCode != 200) {
        throw SupabaseChatCoreStorageException(
          'Download failed (${response.statusCode})',
        );
      }
      _bytes = response.bodyBytes;
      await _player.setSource(
        BytesSource(_bytes!, mimeType: voiceMimeType(widget.message.source)),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Cannot play audio: $e')));
      }
    }
  }

  Future<void> _toggle() => _guard(() async {
    if (_state == PlayerState.playing) return _player.pause();
    await _ensureSource();
    await _player.resume();
  });

  Future<void> _seek(double fraction) => _guard(() async {
    await _ensureSource();
    final target = widget.message.duration * fraction.clamp(0.0, 1.0);
    await _player.seek(target);
    if (mounted) setState(() => _position = target);
  });

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    final mine = widget.isSentByMe;
    final background = mine ? palette.sentBubble : palette.receivedBubble;
    final meta = mine ? palette.sentMeta : palette.receivedMeta;
    final accent = mine ? palette.sentMeta : palette.accent;
    final total = widget.message.duration;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final playing = _state == PlayerState.playing;

    return Container(
      width: 260,
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        spacing: 10,
        children: [
          Material(
            color: accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _loading ? null : _toggle,
              child: SizedBox.square(
                dimension: 44,
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 150),
                        child: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(playing),
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) =>
                        _seek(d.localPosition.dx / constraints.maxWidth),
                    onHorizontalDragUpdate: (d) =>
                        _seek(d.localPosition.dx / constraints.maxWidth),
                    child: SizedBox(
                      height: 28,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _WaveformPainter(
                          bars: _bars,
                          progress: progress,
                          played: accent,
                          unplayed: meta.withValues(alpha: .45),
                        ),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Text(
                      formatDuration(
                        _state == PlayerState.stopped &&
                                _position == Duration.zero
                            ? total
                            : _position,
                      ),
                      style: TextStyle(
                        color: meta,
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    ?widget.footer,
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.played,
    required this.unplayed,
  });

  final List<double> bars;
  final double progress;
  final Color played;
  final Color unplayed;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const gap = 2.0;
    final width = math.max(
      1.5,
      (size.width - gap * (bars.length - 1)) / bars.length,
    );
    final paint = Paint();
    for (var i = 0; i < bars.length; i++) {
      final x = i * (width + gap);
      final h = math.max(3.0, bars[i] * size.height);
      paint.color = (i + .5) / bars.length <= progress ? played : unplayed;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, width, h),
          Radius.circular(width / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress || old.played != played || old.bars != bars;
}
