import 'other_platform.dart' if (dart.library.html) './web_platform.dart';
import 'platforms_widgets_binding.dart';

PlatformsWidgetsBinding get widgetsBinding => getInstance();
