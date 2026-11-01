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
    PhotoLayout? layout,
  }) async {
    layout ??= event.layout;
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

    if (event.print.cutMarks) _drawCutMarks(canvas, layout, dpi, wPx.toDouble(), hPx.toDouble());

    final picture = recorder.endRecording();
    final image = await picture.toImage(wPx, hPx);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Short ticks on the sheet edges at every photo-box edge, so magnets can be cut straight.
  static void _drawCutMarks(Canvas canvas, PhotoLayout layout, double dpi, double w, double h) {
    final xs = <double>{}, ys = <double>{};
    for (final e in layout.elements) {
      if (e.type != ElementType.photo) continue;
      xs..add(e.x * dpi)..add((e.x + e.w) * dpi);
      ys..add(e.y * dpi)..add((e.y + e.h) * dpi);
    }
    final len = 0.12 * dpi;
    final paint = Paint()
      ..color = const Color(0xFF555555)
      ..strokeWidth = math.max(1, dpi / 150);
    for (final x in xs) {
      if (x <= 1 || x >= w - 1) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, len), paint);
      canvas.drawLine(Offset(x, h - len), Offset(x, h), paint);
    }
    for (final y in ys) {
      if (y <= 1 || y >= h - 1) continue;
      canvas.drawLine(Offset(0, y), Offset(len, y), paint);
      canvas.drawLine(Offset(w - len, y), Offset(w, y), paint);
    }
  }

  /// Printer calibration sheet: a border 3 mm inside the paper edge, centre cross and mm rulers.
  static Future<Uint8List> calibrationSheet(PaperSize paper, {double dpi = 300}) async {
    final wPx = (paper.w * dpi).round(), hPx = (paper.h * dpi).round();
    final w = wPx.toDouble(), h = hPx.toDouble();
    final mm = dpi / 25.4;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    final line = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(Rect.fromLTWH(3 * mm, 3 * mm, w - 6 * mm, h - 6 * mm), line);
    canvas.drawLine(Offset(w / 2, h / 2 - 10 * mm), Offset(w / 2, h / 2 + 10 * mm), line);
    canvas.drawLine(Offset(w / 2 - 10 * mm, h / 2), Offset(w / 2 + 10 * mm, h / 2), line);
    // mm rulers from each edge (10 mm long, tick every 1 mm, long tick every 5)
    final tick = Paint()
      ..color = brandOrange
      ..strokeWidth = 2;
    for (var i = 0; i <= 10; i++) {
      final l = (i % 5 == 0 ? 4 : 2) * mm;
      canvas.drawLine(Offset(w / 2 + 6 * mm, i * mm), Offset(w / 2 + 6 * mm + l, i * mm), tick); // top
      canvas.drawLine(Offset(w / 2 + 6 * mm, h - i * mm), Offset(w / 2 + 6 * mm + l, h - i * mm), tick); // bottom
      canvas.drawLine(Offset(i * mm, h / 2 + 6 * mm), Offset(i * mm, h / 2 + 6 * mm + l), tick); // left
      canvas.drawLine(Offset(w - i * mm, h / 2 + 6 * mm), Offset(w - i * mm, h / 2 + 6 * mm + l), tick); // right
    }
    final tp = TextPainter(
      text: TextSpan(
          text: 'OctoSnap calibration ${paper.name}\nBlack border should be 3 mm from every edge.\n'
              'Orange ticks = 1 mm from the edge.',
          style: TextStyle(fontFamily: 'Poppins', fontSize: 0.11 * dpi, color: Colors.black)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w * 0.8);
    tp.paint(canvas, Offset((w - tp.width) / 2, h / 2 + 14 * mm));
    final image = await recorder.endRecording().toImage(wPx, hPx);
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
