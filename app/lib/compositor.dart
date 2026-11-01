import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'models.dart';

/// Builds the final print sheet at [dpi] (default 300) from the layout and the captured shots.
class SheetCompositor {
  static Future<ui.Image> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  static Future<ui.Image?> _decodeFile(String? path) async {
    if (path == null) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    return _decode(await f.readAsBytes());
  }

  static String fillText(String t, BoothEvent event) {
    final d = event.date;
    return t
        .replaceAll('{event}', event.name)
        .replaceAll('{date}', '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}');
  }

  /// [shots] index 0 = photo number 1. Returns PNG bytes.
  static Future<Uint8List> compose({
    required BoothEvent event,
    required List<Uint8List> shots,
    double dpi = 300,
  }) async {
    final layout = event.layout;
    final wPx = (layout.paper.w * dpi).round();
    final hPx = (layout.paper.h * dpi).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, wPx.toDouble(), hPx.toDouble()));

    canvas.drawRect(Rect.fromLTWH(0, 0, wPx.toDouble(), hPx.toDouble()), Paint()..color = Color(layout.background));

    final decoded = <ui.Image>[];
    for (final s in shots) {
      decoded.add(await _decode(s));
    }

    for (final e in layout.elements) {
      final rect = Rect.fromLTWH(e.x * dpi, e.y * dpi, e.w * dpi, e.h * dpi);
      switch (e.type) {
        case ElementType.photo:
          if (decoded.isEmpty) break;
          final img = decoded[(e.photoNumber - 1).clamp(0, decoded.length - 1)];
          drawCover(canvas, img, rect, e.rotation,
              mirror: event.camera.mirrorPhoto, quarterTurns: event.camera.quarterTurns);
          break;
        case ElementType.image:
          final img = await _decodeFile(e.imagePath);
          if (img != null) _drawContain(canvas, img, rect, e.rotation);
          break;
        case ElementType.text:
          _drawText(canvas, fillText(e.text, event), rect, e, dpi);
          break;
      }
    }

    // Full-sheet template on top (PNG with transparent photo windows).
    final tpl = await _decodeFile(layout.templatePath);
    if (tpl != null) {
      canvas.drawImageRect(
        tpl,
        Rect.fromLTWH(0, 0, tpl.width.toDouble(), tpl.height.toDouble()),
        Rect.fromLTWH(0, 0, wPx.toDouble(), hPx.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(wPx, hPx);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Fills [dst] with [img] (center crop), with box rotation, mirror and quarter turns.
  static void drawCover(Canvas canvas, ui.Image img, Rect dst, double rotationDeg,
      {bool mirror = false, int quarterTurns = 0}) {
    canvas.save();
    canvas.translate(dst.center.dx, dst.center.dy);
    canvas.rotate(rotationDeg * math.pi / 180);
    final box = Rect.fromCenter(center: Offset.zero, width: dst.width, height: dst.height);
    canvas.clipRect(box);
    final qt = quarterTurns % 4;
    canvas.rotate(qt * math.pi / 2);
    if (mirror) canvas.scale(-1, 1);
    final sw = img.width.toDouble(), sh = img.height.toDouble();
    final effW = qt.isOdd ? sh : sw;
    final effH = qt.isOdd ? sw : sh;
    final scale = math.max(dst.width / effW, dst.height / effH);
    final out = Rect.fromCenter(center: Offset.zero, width: sw * scale, height: sh * scale);
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, sw, sh), out, Paint()..filterQuality = FilterQuality.high);
    canvas.restore();
  }

  static void _drawContain(Canvas canvas, ui.Image img, Rect dst, double rotationDeg) {
    canvas.save();
    canvas.translate(dst.center.dx, dst.center.dy);
    canvas.rotate(rotationDeg * math.pi / 180);
    final sw = img.width.toDouble(), sh = img.height.toDouble();
    final scale = math.min(dst.width / sw, dst.height / sh);
    final out = Rect.fromCenter(center: Offset.zero, width: sw * scale, height: sh * scale);
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, sw, sh), out, Paint()..filterQuality = FilterQuality.high);
    canvas.restore();
  }

  static void _drawText(Canvas canvas, String text, Rect dst, LayoutElement e, double dpi) {
    final style = TextStyle(
      fontFamily: 'Poppins',
      fontSize: e.fontSize / 72 * dpi,
      color: Color(e.color),
      fontWeight: FontWeight.w600,
    );
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: dst.width);
    canvas.save();
    canvas.translate(dst.center.dx, dst.center.dy);
    canvas.rotate(e.rotation * math.pi / 180);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }
}
