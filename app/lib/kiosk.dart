import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// Windows / desktop full-screen (kiosk) toggle. No-op on Android/iOS.
class Kiosk {
  static bool get supported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  static bool _ready = false;

  static Future<void> init() async {
    if (!supported) return;
    try {
      await windowManager.ensureInitialized();
      _ready = true;
    } catch (_) {}
  }

  static Future<bool> isFullScreen() async {
    if (!_ready) return false;
    try {
      return await windowManager.isFullScreen();
    } catch (_) {
      return false;
    }
  }

  static Future<void> setFullScreen(bool on) async {
    if (!_ready) return;
    try {
      await windowManager.setFullScreen(on);
    } catch (_) {}
  }

  static Future<void> toggle() async => setFullScreen(!await isFullScreen());
}
