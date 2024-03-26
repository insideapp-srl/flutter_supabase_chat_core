import 'package:flutter/material.dart';

abstract class PlatformsWidgetsBinding {
  void addObserver(WidgetsBindingObserver state);
  void removeObserver(WidgetsBindingObserver state);
}
