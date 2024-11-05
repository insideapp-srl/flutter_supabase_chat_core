import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

extension MessageStatusEx on types.Status {
  IconData get icon {
    switch (this) {
      case types.Status.delivered:
        return Icons.done_all;
      case types.Status.error:
        return Icons.error_outline;
      case types.Status.seen:
        return Icons.done_all;
      case types.Status.sending:
        return Icons.timelapse;
      case types.Status.sent:
        return Icons.done;
    }
  }
}
