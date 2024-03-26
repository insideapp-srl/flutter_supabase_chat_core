import 'package:flutter/material.dart';

import 'platforms_widgets_binding.dart';

PlatformsWidgetsBinding getInstance() => OtherPlatformsWidgetsBinding();

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
