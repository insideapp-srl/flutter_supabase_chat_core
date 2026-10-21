import 'other_platform.dart' if (dart.library.js_interop) 'web_platform.dart';
import 'platforms_widgets_binding.dart';

/// Platform-specific app lifecycle binding, created once: the web
/// implementation keeps the focus/blur listeners it registered, so
/// removeObserver must be called on the same instance as addObserver.
final PlatformsWidgetsBinding widgetsBinding = getInstance();
