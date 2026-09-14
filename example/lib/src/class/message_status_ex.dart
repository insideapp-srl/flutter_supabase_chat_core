import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;

extension MessageStatusEx on core.MessageStatus {
  IconData get icon {
    switch (this) {
      case core.MessageStatus.delivered:
        return Icons.done_all;
      case core.MessageStatus.error:
        return Icons.error_outline;
      case core.MessageStatus.seen:
        return Icons.done_all;
      case core.MessageStatus.sending:
        return Icons.timelapse;
      case core.MessageStatus.sent:
        return Icons.done;
    }
  }
}
