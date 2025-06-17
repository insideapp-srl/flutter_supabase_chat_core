import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'platforms_widgets_binding.dart';

PlatformsWidgetsBinding getInstance() => WebWidgetsBinding();

class WebWidgetsBinding extends PlatformsWidgetsBinding {
  late JSFunction _focusListener;
  late JSFunction _blurListener;

  @override
  void addObserver(WidgetsBindingObserver state) {
    _focusListener = ((web.Event _) {
      state.didChangeAppLifecycleState(AppLifecycleState.resumed);
    }).toJS;

    _blurListener = ((web.Event _) {
      state.didChangeAppLifecycleState(AppLifecycleState.paused);
    }).toJS;

    web.window.addEventListener('focus', _focusListener);
    web.window.addEventListener('blur', _blurListener);
  }

  @override
  void removeObserver(WidgetsBindingObserver state) {
    web.window.removeEventListener('focus', _focusListener);
    web.window.removeEventListener('blur', _blurListener);
  }
}
