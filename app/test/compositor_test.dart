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
}
