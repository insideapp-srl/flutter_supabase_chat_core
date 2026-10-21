import 'package:flutter/material.dart';

import 'platforms_widgets_binding.dart';

/// Creates the binding for the current platform.
PlatformsWidgetsBinding getInstance() => OtherPlatformsWidgetsBinding();

/// Native platforms: Flutter's own [WidgetsBinding] lifecycle events.
class OtherPlatformsWidgetsBinding extends PlatformsWidgetsBinding {
  @override
  void addObserver(WidgetsBindingObserver state) {
    WidgetsBinding.instance.addObserver(state);
  }

  @override
  void removeObserver(WidgetsBindingObserver state) {
    WidgetsBinding.instance.removeObserver(state);
  }
}
