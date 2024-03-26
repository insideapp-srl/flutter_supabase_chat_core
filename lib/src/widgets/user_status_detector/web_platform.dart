// ignore: avoid_web_libraries_in_flutter
import 'dart:html';

import 'package:flutter/material.dart';

import 'platforms_widgets_binding.dart';

PlatformsWidgetsBinding getInstance() => WebWidgetsBinding();

class WebWidgetsBinding extends PlatformsWidgetsBinding {
  @override
  void addObserver(WidgetsBindingObserver state) {
    window.addEventListener('focus', (event) => onFocus(event, state));
    window.addEventListener('blur', (event) => onBlur(event, state));
  }

  @override
  void removeObserver(WidgetsBindingObserver state) {
    window.removeEventListener('focus', (event) => onFocus(event, state));
    window.removeEventListener('blur', (event) => onBlur(event, state));
  }

  void onFocus(Event e, WidgetsBindingObserver state) {
    state.didChangeAppLifecycleState(AppLifecycleState.resumed);
  }

  void onBlur(Event e, WidgetsBindingObserver state) {
    state.didChangeAppLifecycleState(AppLifecycleState.paused);
  }
}
