import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Swipe a message to the left to reply to it, as in Telegram: the bubble
/// follows the finger, a reply icon fades in, and releasing past the
/// threshold triggers [onReply] (with a light haptic tick).
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, required this.onReply});

  final Widget child;
  final VoidCallback onReply;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const _threshold = 64.0;
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addListener(() => setState(() => _dx = _from * (1 - _back.value)));
  double _dx = 0;
  double _from = 0;
  bool _armed = false;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails details) {
    setState(() {
      _dx = (_dx + details.delta.dx).clamp(-_threshold * 1.4, 0);
    });
    final armed = _dx <= -_threshold;
    if (armed && !_armed) HapticFeedback.selectionClick();
    _armed = armed;
  }

  void _end(DragEndDetails details) {
    if (_armed) widget.onReply();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (-_dx / _threshold).clamp(0.0, 1.0);
    final palette = ChatPalette.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          Positioned(
            right: 12,
            child: Opacity(
              opacity: progress,
              child: Transform.scale(
                scale: .6 + .4 * progress,
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: palette.serviceChip,
                  child: const Icon(
                    Icons.reply_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        ],
      ),
    );
  }
}
