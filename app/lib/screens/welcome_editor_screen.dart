import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../storage.dart';

/// The guest-facing start screen; used by the editor preview and the live booth.
class WelcomeView extends StatelessWidget {
  final WelcomeSettings s;
  final VoidCallback? onStart;
  const WelcomeView({super.key, required this.s, this.onStart});

  @override
  Widget build(BuildContext context) {
    final bg = s.backgroundImage != null && File(s.backgroundImage!).existsSync()
        ? DecorationImage(image: FileImage(File(s.backgroundImage!)), fit: BoxFit.cover)
        : null;
    return GestureDetector(
      onTap: onStart,
      child: Container(
        decoration: BoxDecoration(color: Color(s.background), image: bg),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w800, color: Colors.white)),
              const SizedBox(height: 12),
              Text(s.subtitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, color: Colors.white70)),
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 20),
                decoration: BoxDecoration(color: Color(s.accent), borderRadius: BorderRadius.circular(40)),
                child: Text(s.buttonText,
                    style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
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
        const SizedBox(height: 12),
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
    final preview = AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(borderRadius: BorderRadius.circular(12), child: WelcomeView(s: s)),
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
        return Column(children: [Padding(padding: const EdgeInsets.all(16), child: preview), Expanded(child: form)]);
      }),
    );
  }
}
