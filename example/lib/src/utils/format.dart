import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;

/// Compact timestamp for lists: time today, weekday this week, date before.
String formatListTime(BuildContext context, DateTime? date) {
  if (date == null) return '';
  final local = date.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final localizations = MaterialLocalizations.of(context);
  // 24h like the bubbles' timestamps (flyer_chat_* messages use HH:mm).
  if (day == today) return formatTime(local);
  if (today.difference(day).inDays == 1) return 'Yesterday';
  if (today.difference(day).inDays < 7) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[local.weekday - 1];
  }
  return localizations.formatShortDate(local);
}

/// `HH:mm` local time.
String formatTime(DateTime date) {
  final local = date.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// Day separator label in a conversation: "Today", "Yesterday", the
/// weekday within a week, the full date before.
String formatDayHeader(BuildContext context, DateTime date) {
  final local = date.toLocal();
  final now = DateTime.now();
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(local.year, local.month, local.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  final localizations = MaterialLocalizations.of(context);
  if (local.year == now.year) return localizations.formatMediumDate(local);
  return localizations.formatFullDate(local);
}

/// "last seen ..." label for a user's [lastSeen].
String formatLastSeen(DateTime? lastSeen) {
  if (lastSeen == null) return 'offline';
  final diff = DateTime.now().difference(lastSeen.toLocal());
  if (diff.inMinutes < 1) return 'last seen just now';
  if (diff.inMinutes < 60) return 'last seen ${diff.inMinutes} min ago';
  if (diff.inHours < 24) return 'last seen ${diff.inHours} h ago';
  if (diff.inDays < 7) return 'last seen ${diff.inDays} d ago';
  return 'last seen a while ago';
}

/// One-line preview of a message for the rooms list, with a matching icon.
({IconData? icon, String text}) messagePreview(core.Message? message) =>
    switch (message) {
      null => (icon: null, text: 'No messages yet'),
      core.TextMessage(:final text) => (icon: null, text: text),
      core.ImageMessage() => (icon: Icons.photo_outlined, text: 'Photo'),
      core.FileMessage(:final name) => (
        icon: Icons.insert_drive_file_outlined,
        text: name,
      ),
      core.AudioMessage(:final duration) => (
        icon: Icons.mic_none_rounded,
        text: 'Voice message (${formatDuration(duration)})',
      ),
      core.VideoMessage() => (icon: Icons.videocam_outlined, text: 'Video'),
      _ => (icon: Icons.info_outline, text: 'Message'),
    };

/// `m:ss` duration.
String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// Human file size (KB/MB).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
