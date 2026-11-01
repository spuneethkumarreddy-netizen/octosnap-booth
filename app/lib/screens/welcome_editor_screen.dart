import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../storage.dart';

/// The guest-facing start screen; used by the editor preview and the live booth.
/// Items: 0 = title, 1 = subtitle, 2 = button. Each sits at its own (x, y) centre.
class WelcomeView extends StatelessWidget {
  final WelcomeSettings s;
  final VoidCallback? onStart;
  final Widget? camera; // live camera shown behind the text when enabled
  final int? selected;
  final ValueChanged<int>? onSelect;
  final void Function(int item, Offset fractionDelta)? onMove;
  final ValueChanged<int>? onMoveStart;
  const WelcomeView({
    super.key,
    required this.s,
    this.onStart,
    this.camera,
    this.selected,
    this.onSelect,
    this.onMove,
    this.onMoveStart,
  });

  static const _shadow = [Shadow(blurRadius: 12, color: Colors.black87)];

  @override
  Widget build(BuildContext context) {
    final useCam = s.cameraPreview && camera != null;
    final bg = !useCam && s.backgroundImage != null && File(s.backgroundImage!).existsSync()
        ? DecorationImage(image: FileImage(File(s.backgroundImage!)), fit: BoxFit.cover)
        : null;
    return GestureDetector(
      onTap: onStart,
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;
        final u = math.min(w, h);
        Widget place(int i, WelcomeItem it, Widget child) {
          if (!it.visible) return const SizedBox.shrink();
          final editable = onMove != null;
          Widget body = ConstrainedBox(constraints: BoxConstraints(maxWidth: w * 0.95), child: child);
          if (editable) {
            body = GestureDetector(
              onTap: () => onSelect?.call(i),
              onPanStart: (_) {
                onSelect?.call(i);
                onMoveStart?.call(i);
              },
              onPanUpdate: (d) => onMove!(i, Offset(d.delta.dx / w, d.delta.dy / h)),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  border: Border.all(color: selected == i ? const Color(0xFFF47B20) : Colors.white24, width: selected == i ? 2 : 1),
                ),
                child: body,
              ),
            );
          }
          return Positioned(
            left: it.x * w,
            top: it.y * h,
            child: FractionalTranslation(translation: const Offset(-0.5, -0.5), child: body),
          );
        }

        return Container(
          decoration: BoxDecoration(color: Color(s.background), image: bg),
          child: Stack(clipBehavior: Clip.hardEdge, children: [
            if (useCam) Positioned.fill(child: camera!),
            place(
                0,
                s.titleItem,
                Text(s.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: u * 0.11 * s.titleItem.scale,
                        fontWeight: FontWeight.w800,
                        color: Color(s.titleItem.color),
                        shadows: _shadow))),
            place(
                1,
                s.subtitleItem,
                Text(s.subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: u * 0.045 * s.subtitleItem.scale,
                        fontWeight: FontWeight.w500,
                        color: Color(s.subtitleItem.color),
                        shadows: _shadow))),
            place(
                2,
                s.buttonItem,
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: u * 0.10 * s.buttonItem.scale, vertical: u * 0.035 * s.buttonItem.scale),
                  decoration: BoxDecoration(
                      color: Color(s.accent),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black45)]),
                  child: Text(s.buttonText,
                      style: TextStyle(
                          fontSize: u * 0.055 * s.buttonItem.scale,
                          fontWeight: FontWeight.w700,
                          color: Color(s.buttonItem.color))),
                )),
          ]),
        );
      }),
    );
  }
}

class WelcomeEditorScreen extends StatefulWidget {
  final BoothEvent event;
  const WelcomeEditorScreen({super.key, required this.event});
  @override
  State<WelcomeEditorScreen> createState() => _WelcomeEditorScreenState();
}

class _WelcomeEditorScreenState extends State<WelcomeEditorScreen> {
  static const swatches = [0xFF1F1F24, 0xFFF47B20, 0xFFFFFFFF, 0xFF000000, 0xFF0F4C81, 0xFFB5179E, 0xFF2D6A4F, 0xFFE63946];
  WelcomeSettings get s => widget.event.welcome;
  int sel = 0;

  WelcomeItem get item => [s.titleItem, s.subtitleItem, s.buttonItem][sel];

  Widget _itemControls() {
    final it = item;
    const names = ['Title', 'Subtitle', 'Button'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SegmentedButton<int>(
        segments: [for (var i = 0; i < 3; i++) ButtonSegment(value: i, label: Text(names[i]))],
        selected: {sel},
        onSelectionChanged: (v) => setState(() => sel = v.first),
      ),
      const SizedBox(height: 4),
      const Text('Preview lo text ni drag chesi ekkadaina pettochu.', style: TextStyle(color: Colors.white60, fontSize: 12)),
      Row(children: [
        const SizedBox(width: 60, child: Text('Size')),
        Expanded(
          child: Slider(min: 0.4, max: 2.5, value: it.scale.clamp(0.4, 2.5), onChanged: (v) => setState(() => it.scale = v)),
        ),
      ]),
      Wrap(spacing: 4, children: [
        IconButton(tooltip: 'Up', onPressed: () => setState(() => it.y = (it.y - 0.01).clamp(0, 1)), icon: const Icon(Icons.arrow_upward)),
        IconButton(tooltip: 'Down', onPressed: () => setState(() => it.y = (it.y + 0.01).clamp(0, 1)), icon: const Icon(Icons.arrow_downward)),
        IconButton(tooltip: 'Left', onPressed: () => setState(() => it.x = (it.x - 0.01).clamp(0, 1)), icon: const Icon(Icons.arrow_back)),
        IconButton(tooltip: 'Right', onPressed: () => setState(() => it.x = (it.x + 0.01).clamp(0, 1)), icon: const Icon(Icons.arrow_forward)),
        TextButton(onPressed: () => setState(() => it.x = 0.5), child: const Text('Center')),
        FilterChip(label: const Text('Show'), selected: it.visible, onSelected: (v) => setState(() => it.visible = v)),
      ]),
      _colors(sel == 2 ? 'Button text' : 'Text colour', it.color, (c) => it.color = c),
    ]);
  }

  Widget _colors(String label, int value, ValueChanged<int> onPick) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          SizedBox(width: 110, child: Text(label)),
          ...swatches.map((c) => GestureDetector(
                onTap: () => setState(() => onPick(c)),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(color: value == c ? brandOrange : Colors.white24, width: value == c ? 3 : 1),
                  ),
                ),
              )),
        ]),
      );

  Future<void> _pickBg() async {
    final r = await FilePicker.pickFiles(type: FileType.image);
    final path = r.isEmpty ? null : r.first.path;
    if (path == null) return;
    final saved = await EventStore.instance.importAsset(path);
    setState(() => s.backgroundImage = saved);
  }

  @override
  Widget build(BuildContext context) {
    final form = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextFormField(
          initialValue: s.title,
          decoration: const InputDecoration(labelText: 'Title'),
          onChanged: (v) => setState(() => s.title = v),
        ),
        TextFormField(
          initialValue: s.subtitle,
          decoration: const InputDecoration(labelText: 'Subtitle'),
          onChanged: (v) => setState(() => s.subtitle = v),
        ),
        TextFormField(
          initialValue: s.buttonText,
          decoration: const InputDecoration(labelText: 'Button text'),
          onChanged: (v) => setState(() => s.buttonText = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Live camera preview behind text'),
          value: s.cameraPreview,
          onChanged: (v) => setState(() => s.cameraPreview = v),
        ),
        const SizedBox(height: 8),
        _itemControls(),
        const Divider(),
        _colors('Background', s.background, (c) => s.background = c),
        _colors('Button', s.accent, (c) => s.accent = c),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton.icon(onPressed: _pickBg, icon: const Icon(Icons.image), label: const Text('Background image')),
          if (s.backgroundImage != null)
            TextButton(onPressed: () => setState(() => s.backgroundImage = null), child: const Text('Remove')),
        ]),
      ],
    );
    final screen = MediaQuery.of(context).size;
    final preview = AspectRatio(
      aspectRatio: screen.width / screen.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: WelcomeView(
          s: s,
          camera: s.cameraPreview
              ? Container(
                  color: Colors.blueGrey.shade800,
                  alignment: Alignment.bottomCenter,
                  padding: const EdgeInsets.all(8),
                  child: const Text('camera preview', style: TextStyle(color: Colors.white38)))
              : null,
          selected: sel,
          onSelect: (i) => setState(() => sel = i),
          onMove: (i, d) => setState(() {
            final it = [s.titleItem, s.subtitleItem, s.buttonItem][i];
            it.x = (it.x + d.dx).clamp(0.0, 1.0);
            it.y = (it.y + d.dy).clamp(0.0, 1.0);
          }),
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome screen')),
      body: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth > 900) {
          return Row(children: [
            Expanded(child: Padding(padding: const EdgeInsets.all(16), child: Center(child: preview))),
            SizedBox(width: 420, child: form),
          ]);
        }
        return Column(children: [
          SizedBox(height: c.maxHeight * 0.48, child: Padding(padding: const EdgeInsets.all(8), child: Center(child: preview))),
          Expanded(child: form),
        ]);
      }),
    );
  }
}
