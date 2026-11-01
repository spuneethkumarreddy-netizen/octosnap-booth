import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../compositor.dart';
import '../models.dart';
import '../storage.dart';

/// LumaBooth-style photo layout editor: paper size, full-sheet template,
/// photo boxes (drag / resize / W,H,X,Y / rotate / photo number), text, logos.
class LayoutEditorScreen extends StatefulWidget {
  final BoothEvent event;
  const LayoutEditorScreen({super.key, required this.event});
  @override
  State<LayoutEditorScreen> createState() => _LayoutEditorScreenState();
}

class _LayoutEditorScreenState extends State<LayoutEditorScreen> {
  LayoutElement? selected;
  bool showTemplate = true;
  PhotoLayout get layout => widget.event.layout;

  double _snap(double v) => (v * 20).roundToDouble() / 20; // 0.05 inch grid

  // ---------- actions ----------
  void _add(ElementType t) {
    final nextNum = layout.shotCount + (layout.elements.any((e) => e.type == ElementType.photo) ? 1 : 0);
    final e = LayoutElement(
      type: t,
      x: 0.25,
      y: 0.25,
      w: t == ElementType.text ? math.min(3, layout.paper.w - 0.5) : 2,
      h: t == ElementType.text ? 0.6 : 2,
      photoNumber: t == ElementType.photo ? nextNum : 1,
    );
    setState(() {
      layout.elements.add(e);
      selected = e;
    });
  }

  Future<void> _addLogo() async {
    final r = await FilePicker.pickFiles(type: FileType.image);
    final path = r.isEmpty ? null : r.first.path;
    if (path == null) return;
    final saved = await EventStore.instance.importAsset(path);
    final e = LayoutElement(type: ElementType.image, x: 0.25, y: 0.25, w: 1.5, h: 1, imagePath: saved);
    setState(() {
      layout.elements.add(e);
      selected = e;
    });
  }

  Future<void> _importTemplate() async {
    // FileType.image: Android galleries/WhatsApp folders often don't tag files as .png,
    // so a png-only filter greys them out. Accept any image, then check for real PNG.
    final r = await FilePicker.pickFiles(type: FileType.image);
    final path = r.isEmpty ? null : r.first.path;
    if (path == null) return;
    final head = await File(path).openRead(0, 8).fold<List<int>>([], (a, b) => a..addAll(b));
    final isPng = head.length >= 8 && head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47;
    if (!isPng && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          duration: Duration(seconds: 8),
          content: Text('This image is not a PNG, so it has no transparent photo window. '
              'WhatsApp converts photos to JPG: send the template as a Document instead. '
              'Imported anyway; photos will go behind it only where it is transparent.')));
    }
    final saved = await EventStore.instance.importAsset(path);
    // Match paper orientation to the template's aspect ratio when it clearly differs.
    final bytes = await File(saved).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final img = (await codec.getNextFrame()).image;
    setState(() {
      layout.templatePath = saved;
      final tplLandscape = img.width > img.height;
      final paperLandscape = layout.paper.w > layout.paper.h;
      if (tplLandscape != paperLandscape) {
        layout.paper = PaperSize(layout.paper.name, layout.paper.h, layout.paper.w);
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Template ${img.width}x${img.height}px imported. '
              'Best quality: ${(layout.paper.w * 300).round()}x${(layout.paper.h * 300).round()}px (300 DPI).')));
    }
  }

  Future<void> _customPaper() async {
    final w = TextEditingController(text: layout.paper.w.toString());
    final h = TextEditingController(text: layout.paper.h.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Custom paper size (inches)'),
        content: Row(children: [
          Expanded(child: TextField(controller: w, decoration: const InputDecoration(labelText: 'Width'), keyboardType: TextInputType.number)),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: h, decoration: const InputDecoration(labelText: 'Height'), keyboardType: TextInputType.number)),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('OK'))],
      ),
    );
    final wv = double.tryParse(w.text), hv = double.tryParse(h.text);
    if (ok == true && wv != null && hv != null && wv > 0 && hv > 0) {
      setState(() => layout.paper = PaperSize('Custom', wv, hv));
    }
  }

  void _applyPreset(PhotoLayout p) {
    setState(() {
      layout.paper = p.paper;
      layout.elements
        ..clear()
        ..addAll(p.elements);
      selected = null;
    });
  }

  Future<void> _previewSheet() async {
    // Render the real 300 DPI sheet using sample shots so the operator can check alignment.
    final shots = <Uint8List>[];
    for (var i = 0; i < layout.shotCount; i++) {
      shots.add(await _sampleShot(i + 1));
    }
    final png = await SheetCompositor.compose(event: widget.event, shots: shots);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (c) => Dialog(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Print preview · ${(layout.paper.w * 300).round()} x ${(layout.paper.h * 300).round()} px @ 300 DPI'),
          ),
          Flexible(child: InteractiveViewer(child: Image.memory(png))),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
        ]),
      ),
    );
  }

  static Future<Uint8List> _sampleShot(int n) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    const w = 1200.0, h = 900.0;
    final paint = Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(w, h), [const Color(0xFFF47B20), const Color(0xFF5B2C83)]);
    c.drawRect(const Rect.fromLTWH(0, 0, w, h), paint);
    final tp = TextPainter(
      text: TextSpan(text: 'Photo $n', style: const TextStyle(fontSize: 160, color: Colors.white, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, Offset((w - tp.width) / 2, (h - tp.height) / 2));
    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  // ---------- canvas ----------
  Widget _canvas(BoxConstraints c) {
    final paper = layout.paper;
    final scale = math.min((c.maxWidth - 32) / paper.w, (c.maxHeight - 32) / paper.h);
    final sheetW = paper.w * scale, sheetH = paper.h * scale;
    return Center(
      child: GestureDetector(
        onTap: () => setState(() => selected = null),
        child: Container(
          width: sheetW,
          height: sheetH,
          decoration: BoxDecoration(
            color: Color(layout.background),
            boxShadow: const [BoxShadow(blurRadius: 16, color: Colors.black54)],
          ),
          child: Stack(clipBehavior: Clip.hardEdge, children: [
            for (final e in layout.elements) _elementWidget(e, scale),
            if (showTemplate && layout.templatePath != null && File(layout.templatePath!).existsSync())
              Positioned.fill(
                child: IgnorePointer(child: Image.file(File(layout.templatePath!), fit: BoxFit.fill)),
              ),
            // handles on top of the template so boxes stay editable
            if (selected != null && layout.elements.contains(selected)) _handles(selected!, scale),
          ]),
        ),
      ),
    );
  }

  Widget _elementWidget(LayoutElement e, double scale) {
    Widget child;
    switch (e.type) {
      case ElementType.photo:
        child = Container(
          color: brandOrange.withValues(alpha: 0.35),
          alignment: Alignment.center,
          child: FittedBox(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.photo_camera, color: Colors.white),
                Text('${e.photoNumber}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
              ]),
            ),
          ),
        );
        break;
      case ElementType.text:
        child = FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            SheetCompositor.fillText(e.text, widget.event),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: e.fontSize / 72 * scale, color: Color(e.color), fontWeight: FontWeight.w600),
          ),
        );
        break;
      case ElementType.image:
        child = e.imagePath != null && File(e.imagePath!).existsSync()
            ? Image.file(File(e.imagePath!), fit: BoxFit.contain)
            : const Icon(Icons.broken_image);
        break;
    }
    return Positioned(
      left: e.x * scale,
      top: e.y * scale,
      width: e.w * scale,
      height: e.h * scale,
      child: Transform.rotate(
        angle: e.rotation * math.pi / 180,
        child: GestureDetector(
          onTap: () => setState(() => selected = e),
          onPanStart: (_) => setState(() => selected = e),
          onPanUpdate: (d) => setState(() {
            e.x += d.delta.dx / scale;
            e.y += d.delta.dy / scale;
          }),
          onPanEnd: (_) => setState(() {
            e.x = _snap(e.x);
            e.y = _snap(e.y);
          }),
          child: child,
        ),
      ),
    );
  }

  Widget _handles(LayoutElement e, double scale) {
    const hs = 22.0;
    return Positioned(
      left: e.x * scale,
      top: e.y * scale,
      width: e.w * scale,
      height: e.h * scale,
      child: Transform.rotate(
        angle: e.rotation * math.pi / 180,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Container(decoration: BoxDecoration(border: Border.all(color: brandOrange, width: 2))),
            ),
          ),
          // move handle (center) so a selected box can be dragged even under a template
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanUpdate: (d) => setState(() {
                e.x += d.delta.dx / scale;
                e.y += d.delta.dy / scale;
              }),
              onPanEnd: (_) => setState(() {
                e.x = _snap(e.x);
                e.y = _snap(e.y);
              }),
            ),
          ),
          Positioned(
            right: -hs / 2,
            bottom: -hs / 2,
            child: GestureDetector(
              onPanUpdate: (d) => setState(() {
                e.w = math.max(0.2, e.w + d.delta.dx / scale);
                e.h = math.max(0.2, e.h + d.delta.dy / scale);
              }),
              onPanEnd: (_) => setState(() {
                e.w = _snap(e.w);
                e.h = _snap(e.h);
              }),
              child: Container(
                width: hs,
                height: hs,
                decoration: BoxDecoration(
                    color: brandOrange, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                child: const Icon(Icons.open_in_full, size: 12, color: Colors.white),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // ---------- properties ----------
  Widget _num(String label, double value, ValueChanged<double> onChanged, {String suffix = 'in'}) {
    return SizedBox(
      width: 92,
      child: TextFormField(
        key: ValueKey('$label-${identityHashCode(selected)}-${value.toStringAsFixed(2)}'),
        initialValue: value.toStringAsFixed(2),
        decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        onFieldSubmitted: (v) {
          final d = double.tryParse(v);
          if (d != null) setState(() => onChanged(d));
        },
      ),
    );
  }

  Widget _props() {
    final e = selected;
    if (e == null || !layout.elements.contains(e)) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Tap a box to edit it. Same photo number in many boxes = same shot repeated (e.g. six magnets of one photo).',
            style: TextStyle(color: Colors.white60)),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(switch (e.type) { ElementType.photo => 'Photo box', ElementType.text => 'Text', ElementType.image => 'Logo / image' },
            style: const TextStyle(fontWeight: FontWeight.w700, color: brandOrange)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _num('W', e.w, (v) => e.w = math.max(0.1, v)),
          _num('H', e.h, (v) => e.h = math.max(0.1, v)),
          _num('X', e.x, (v) => e.x = v),
          _num('Y', e.y, (v) => e.y = v),
          _num('Rotate', e.rotation, (v) => e.rotation = v, suffix: '°'),
        ]),
        if (e.type == ElementType.photo)
          Row(children: [
            const Text('Photo #'),
            IconButton(
                onPressed: e.photoNumber > 1 ? () => setState(() => e.photoNumber--) : null,
                icon: const Icon(Icons.remove_circle_outline)),
            Text('${e.photoNumber}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            IconButton(onPressed: () => setState(() => e.photoNumber++), icon: const Icon(Icons.add_circle_outline)),
          ]),
        if (e.type == ElementType.text) ...[
          TextFormField(
            key: ValueKey('txt-${identityHashCode(e)}'),
            initialValue: e.text,
            decoration: const InputDecoration(labelText: 'Text ({event}, {date} allowed)'),
            onChanged: (v) => setState(() => e.text = v),
          ),
          Row(children: [
            const Text('Size'),
            Expanded(
              child: Slider(min: 6, max: 96, value: e.fontSize.clamp(6, 96), onChanged: (v) => setState(() => e.fontSize = v)),
            ),
            Text('${e.fontSize.round()}pt'),
          ]),
          Wrap(spacing: 6, children: [
            for (final c in [0xFF1F1F24, 0xFFFFFFFF, 0xFFF47B20, 0xFF000000, 0xFFE63946, 0xFF0F4C81])
              GestureDetector(
                onTap: () => setState(() => e.color = c),
                child: CircleAvatar(
                    radius: 14,
                    backgroundColor: e.color == c ? brandOrange : Colors.white24,
                    child: CircleAvatar(radius: 11, backgroundColor: Color(c))),
              ),
          ]),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
            onPressed: () => setState(() {
              final c = e.copy()
                ..x = e.x + 0.2
                ..y = e.y + 0.2;
              layout.elements.add(c);
              selected = c;
            }),
            icon: const Icon(Icons.copy),
            label: const Text('Duplicate'),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() {
              layout.elements.remove(e);
              layout.elements.add(e);
            }),
            icon: const Icon(Icons.flip_to_front),
            label: const Text('Front'),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() {
              layout.elements.remove(e);
              layout.elements.insert(0, e);
            }),
            icon: const Icon(Icons.flip_to_back),
            label: const Text('Back'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => setState(() {
              layout.elements.remove(e);
              selected = null;
            }),
            icon: const Icon(Icons.delete),
            label: const Text('Delete'),
          ),
        ]),
      ]),
    );
  }

  Widget _toolbar() {
    final isPreset = PaperSize.presets.any((p) => p.name == layout.paper.name && p.w == layout.paper.w && p.h == layout.paper.h);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        DropdownButton<String>(
          value: isPreset ? layout.paper.name : 'Custom',
          items: [
            ...PaperSize.presets.map((p) => DropdownMenuItem(value: p.name, child: Text('Paper ${p.name}'))),
            const DropdownMenuItem(value: 'Custom', child: Text('Custom…')),
          ],
          onChanged: (v) {
            if (v == 'Custom') {
              _customPaper();
            } else {
              setState(() => layout.paper = PaperSize.presets.firstWhere((p) => p.name == v));
            }
          },
        ),
        PopupMenuButton<String>(
          tooltip: 'Presets',
          onSelected: (v) => _applyPreset(switch (v) {
            'single' => PhotoLayout.singlePhoto(),
            'strip' => PhotoLayout.strip3(),
            _ => PhotoLayout.sixMagnets(),
          }),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'magnets', child: Text('6 magnets 2x2 (one shot) on 4x6')),
            PopupMenuItem(value: 'single', child: Text('Single photo 4x6')),
            PopupMenuItem(value: 'strip', child: Text('Strip 2x6, 3 shots')),
          ],
          child: const Chip(avatar: Icon(Icons.auto_awesome, size: 18), label: Text('Presets')),
        ),
        ActionChip(avatar: const Icon(Icons.add_a_photo, size: 18), label: const Text('Photo box'), onPressed: () => _add(ElementType.photo)),
        ActionChip(avatar: const Icon(Icons.text_fields, size: 18), label: const Text('Text'), onPressed: () => _add(ElementType.text)),
        ActionChip(avatar: const Icon(Icons.image, size: 18), label: const Text('Logo'), onPressed: _addLogo),
        ActionChip(avatar: const Icon(Icons.layers, size: 18), label: const Text('Import template PNG'), onPressed: _importTemplate),
        if (layout.templatePath != null) ...[
          FilterChip(label: const Text('Show template'), selected: showTemplate, onSelected: (v) => setState(() => showTemplate = v)),
          ActionChip(label: const Text('Remove template'), onPressed: () => setState(() => layout.templatePath = null)),
        ],
        ActionChip(
          avatar: const Icon(Icons.format_color_fill, size: 18),
          label: const Text('Background'),
          onPressed: () => setState(() {
            const cycle = [0xFFFFFFFF, 0xFF1F1F24, 0xFFF47B20, 0xFF000000];
            layout.background = cycle[(cycle.indexOf(layout.background) + 1) % cycle.length];
          }),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Photo layout · ${layout.paper.name} (${layout.paper.w}" x ${layout.paper.h}")'),
        actions: [
          TextButton.icon(onPressed: _previewSheet, icon: const Icon(Icons.visibility), label: const Text('Preview 300 DPI')),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 900;
        if (wide) {
          return Row(children: [
            Expanded(child: LayoutBuilder(builder: (_, cc) => _canvas(cc))),
            SizedBox(
              width: 400,
              child: ListView(children: [_toolbar(), const Divider(), _props()]),
            ),
          ]);
        }
        return Column(children: [
          _toolbar(),
          Expanded(child: LayoutBuilder(builder: (_, cc) => _canvas(cc))),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: c.maxHeight * 0.38),
            child: SingleChildScrollView(child: _props()),
          ),
        ]);
      }),
    );
  }
}
