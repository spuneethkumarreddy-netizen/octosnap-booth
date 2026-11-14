import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:octosnap_booth/compositor.dart';
import 'package:octosnap_booth/models.dart';

Future<List<int>> _shot() async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 400, 300), Paint()..color = Colors.orange);
  final img = await rec.endRecording().toImage(400, 300);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  test('six magnets on 4x6 renders 1200x1800 at 300 DPI with one shot', () async {
    final ev = BoothEvent(id: 't', name: 'Test', date: DateTime(2026, 11, 1));
    expect(ev.layout.shotCount, 1);
    expect(ev.layout.elements.length, 6);
    final shot = await _shot();
    final png = await SheetCompositor.compose(event: ev, shots: [Uint8List.fromList(shot)]);
    final codec = await ui.instantiateImageCodec(png);
    final img = (await codec.getNextFrame()).image;
    expect(img.width, 1200);
    expect(img.height, 1800);
  });

  test('event json round trip', () {
    final ev = BoothEvent(id: 'x', name: 'Wedding', date: DateTime(2026, 11, 1), layout: PhotoLayout.strip3());
    final back = BoothEvent.fromJson(ev.toJson());
    expect(back.layout.paper.name, '2x6');
    expect(back.layout.shotCount, 3);
  });

  test('Magnets 2x preset: 6x4 landscape, two 2.5x3.5 boxes centred, 1 shot', () async {
    final l = PhotoLayout.twoMagnets();
    expect(l.paper.w, 6);
    expect(l.paper.h, 4);
    final boxes = l.elements.where((x) => x.type == ElementType.photo).toList();
    expect(boxes.length, 2);
    for (final b in boxes) {
      expect(b.w, 2.5);
      expect(b.h, 3.5);
    }
    expect(boxes.first.x, closeTo(6 - (boxes.last.x + 2.5), 1e-9)); // centred
    expect(boxes.first.y, closeTo(0.25, 1e-9));
    expect(l.shotCount, 1);
    expect(l.bleedMm, 1.5);
    final ev = BoothEvent(id: 'm', name: 'Magnets', date: DateTime(2026, 11, 14), layout: l);
    final png = await SheetCompositor.compose(event: ev, shots: [Uint8List.fromList(await _shot())]);
    final img = (await (await ui.instantiateImageCodec(png)).getNextFrame()).image;
    expect(img.width, 1800);
    expect(img.height, 1200);
  });

  test('pair mode: box 1 = shot 1, box 2 = shot 2; json keeps settings', () {
    final l = PhotoLayout.twoMagnets()..pairMode = true;
    expect(l.pairActive, true);
    final p = l.pairLayout();
    expect(p.elements.map((e) => e.photoNumber).toList(), [1, 2]);
    expect(p.shotCount, 2);
    final back = PhotoLayout.fromJson(l.toJson());
    expect(back.pairMode, true);
    expect(back.cropMarks, true);
    final cs = CaptureSettings.fromJson(CaptureSettings(roaming: true, autoAccept: false).toJson());
    expect(cs.roaming, true);
    expect(cs.autoAccept, false);
    expect(CaptureSettings.fromJson({}).autoAccept, true);
  });

  test('print settings: Windows usePrinterSettings round trip, default off', () {
    final ps = PrintSettings(usePrinterSettings: true, printerName: 'EPSON L8050 Series', printerUrl: 'EPSON L8050 Series');
    final back = PrintSettings.fromJson(ps.toJson());
    expect(back.usePrinterSettings, true);
    expect(back.printerName, 'EPSON L8050 Series');
    expect(PrintSettings.fromJson({}).usePrinterSettings, false);
  });
}
