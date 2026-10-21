import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'platforms_widgets_binding.dart';

/// Creates the binding for the current platform.
PlatformsWidgetsBinding getInstance() => WebWidgetsBinding();

/// Web: browser window focus/blur, since browser tabs rarely report
/// Flutter lifecycle changes.
class WebWidgetsBinding extends PlatformsWidgetsBinding {
  JSFunction? _focusListener;
  JSFunction? _blurListener;

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
    if (_focusListener != null) {
      web.window.removeEventListener('focus', _focusListener);
    }
    if (_blurListener != null) {
      web.window.removeEventListener('blur', _blurListener);
    }
  }
}
