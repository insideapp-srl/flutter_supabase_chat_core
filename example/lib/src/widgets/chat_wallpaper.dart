import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Telegram-style chat background: a soft gradient with a faint doodle
/// pattern of chat-themed icons on top.
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.wallpaper,
        ),
      ),
      // The doodles are scattered past the edges: clip them to this box.
      child: ClipRect(
        child: CustomPaint(
          painter: _DoodlePainter(palette.wallpaperPattern),
          child: child,
        ),
      ),
    );
  }
}

class _DoodlePainter extends CustomPainter {
  _DoodlePainter(this.color);

  final Color color;

  static const _icons = [
    Icons.chat_bubble_outline_rounded,
    Icons.favorite_border_rounded,
    Icons.star_border_rounded,
    Icons.music_note_outlined,
    Icons.local_cafe_outlined,
    Icons.camera_alt_outlined,
    Icons.emoji_emotions_outlined,
    Icons.flight_outlined,
    Icons.headphones_outlined,
    Icons.pets_outlined,
    Icons.wb_sunny_outlined,
    Icons.send_outlined,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 64.0;
    final random = math.Random(7);
    for (var y = 0.0; y < size.height + cell; y += cell) {
      final rowOffset = ((y / cell).round().isOdd) ? cell / 2 : 0.0;
      for (var x = -cell; x < size.width + cell; x += cell) {
        final icon = _icons[random.nextInt(_icons.length)];
        final painter = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
              fontSize: 22 + random.nextDouble() * 8,
              fontFamily: icon.fontFamily,
              package: icon.fontPackage,
              color: color,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        canvas
          ..save()
          ..translate(
            x + rowOffset + random.nextDouble() * 12,
            y + random.nextDouble() * 12,
          )
          ..rotate((random.nextDouble() - .5) * .9);
        painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_DoodlePainter oldDelegate) => oldDelegate.color != color;
}

/// Centered translucent "service" chip (dates, notices), as Telegram draws
/// them over the wallpaper.
class ServiceChip extends StatelessWidget {
  const ServiceChip({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = ChatPalette.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: palette.serviceChip,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: palette.onServiceChip,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
