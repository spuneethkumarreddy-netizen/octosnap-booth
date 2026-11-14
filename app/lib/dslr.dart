import 'dart:io';

import 'package:flutter/services.dart';

import 'canon_helper.dart';

/// Canon EOS DSLR / mirrorless.
/// - Android: USB Host + PTP (MethodChannel 'octosnap/dslr', CanonPtpCamera.kt).
/// - Windows: OctoSnap Camera helper (OctoSnapCamera.exe, Canon EDSDK) over HTTP on 127.0.0.1:5514.
class Dslr {
  static const _ch = MethodChannel('octosnap/dslr');

  static bool get supported => Platform.isAndroid || Platform.isWindows;
  static bool get _win => Platform.isWindows;

  /// Opens the camera; asks USB permission the first time (Android). Returns the model name.
  static Future<String> connect() async {
    if (_win) return CanonHelper.instance.connect();
    return (await _ch.invokeMethod<String>('connect')) ?? 'Canon camera';
  }

  static Future<void> startLiveView() => _win ? CanonHelper.instance.startLiveView() : _ch.invokeMethod('startLiveView');

  /// One live-view JPEG, or null when the camera isn't ready yet.
  static Future<Uint8List?> liveFrame() =>
      _win ? CanonHelper.instance.liveFrame() : _ch.invokeMethod<Uint8List>('liveFrame');

  /// Fires the shutter and returns the full-resolution JPEG.
  static Future<Uint8List> capture() async {
    if (_win) return CanonHelper.instance.capture();
    final b = await _ch.invokeMethod<Uint8List>('capture');
    if (b == null) throw 'Camera returned no photo';
    return b;
  }

  /// Photo taken with the CAMERA'S OWN shutter button (sent to the phone/PC), or null if none.
  static Future<Uint8List?> pollExternal() =>
      _win ? CanonHelper.instance.pollExternal() : _ch.invokeMethod<Uint8List>('pollExternal');

  static Future<bool> isConnected() async {
    if (_win) return CanonHelper.instance.isConnected();
    return (await _ch.invokeMethod<bool>('isConnected')) ?? false;
  }

  static Future<void> close() async {
    try {
      if (_win) {
        await CanonHelper.instance.close();
      } else {
        await _ch.invokeMethod('close');
      }
    } catch (_) {}
  }
}
