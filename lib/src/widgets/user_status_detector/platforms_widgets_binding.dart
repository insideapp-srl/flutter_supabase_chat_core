import 'package:flutter/material.dart';

/// Delivers app lifecycle changes (foreground/background) to a
/// [WidgetsBindingObserver] in a platform-appropriate way.
abstract class PlatformsWidgetsBinding {
  /// Starts delivering lifecycle changes to [state].
  void addObserver(WidgetsBindingObserver state);

  /// Stops delivering lifecycle changes to [state].
  void removeObserver(WidgetsBindingObserver state);
}
