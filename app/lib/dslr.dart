import 'dart:io';

import 'package:flutter/services.dart';

/// Canon EOS over USB (Android USB Host + PTP). Windows (EDSDK) comes later.
class Dslr {
  static const _ch = MethodChannel('octosnap/dslr');

  static bool get supported => Platform.isAndroid;

  /// Opens the camera; asks USB permission the first time. Returns the model name.
  static Future<String> connect() async => (await _ch.invokeMethod<String>('connect')) ?? 'Canon camera';

  static Future<void> startLiveView() => _ch.invokeMethod('startLiveView');

  /// One live-view JPEG, or null when the camera isn't ready yet.
  static Future<Uint8List?> liveFrame() => _ch.invokeMethod<Uint8List>('liveFrame');

  /// Fires the shutter and returns the full-resolution JPEG.
  static Future<Uint8List> capture() async {
    final b = await _ch.invokeMethod<Uint8List>('capture');
    if (b == null) throw 'Camera returned no photo';
    return b;
  }

  /// Photo taken with the CAMERA'S OWN shutter button (sent to the phone), or null if none.
  static Future<Uint8List?> pollExternal() => _ch.invokeMethod<Uint8List>('pollExternal');

  static Future<bool> isConnected() async => (await _ch.invokeMethod<bool>('isConnected')) ?? false;

  static Future<void> close() async {
    try {
      await _ch.invokeMethod('close');
    } catch (_) {}
  }
}
