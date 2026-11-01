import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../compositor.dart';
import '../models.dart';
import '../storage.dart';
import 'layout_editor_screen.dart';

/// All templates of an event. With 2 or more, guests pick one after tapping Start.
class LayoutsScreen extends StatefulWidget {
  final BoothEvent event;
  const LayoutsScreen({super.key, required this.event});
  @override
  State<LayoutsScreen> createState() => _LayoutsScreenState();
}

class _LayoutsScreenState extends State<LayoutsScreen> {
  BoothEvent get e => widget.event;
  final Map<PhotoLayout, Future<Uint8List>> _thumbs = {};

  Future<Uint8List> _thumb(PhotoLayout l) =>
      _thumbs.putIfAbsent(l, () => SheetCompositor.compose(event: e, shots: const [], dpi: 50, layout: l));

  Future<void> _edit(int i) async {
    setState(() => e.activeLayout = i);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => LayoutEditorScreen(event: e)));
    await EventStore.instance.save();
    if (mounted) setState(() => _thumbs.remove(e.layouts[i]));
  }

  Future<String?> _askName(String initial) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Template name'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save'))],
      ),
    );
  }

  Future<void> _add() async {
    final preset = await showModalBottomSheet<PhotoLayout>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.grid_view),
              title: const Text('6 magnets (2x2) on 4x6'),
              onTap: () => Navigator.pop(c, PhotoLayout.sixMagnets())),
          ListTile(
              leading: const Icon(Icons.crop_portrait),
              title: const Text('Single photo 4x6'),
              onTap: () => Navigator.pop(c, PhotoLayout.singlePhoto())),
          ListTile(
              leading: const Icon(Icons.view_agenda),
              title: const Text('Strip of 3 (2x6)'),
              onTap: () => Navigator.pop(c, PhotoLayout.strip3())),
          ListTile(
              leading: const Icon(Icons.copy),
              title: Text('Copy of "${e.layout.name}"'),
              onTap: () => Navigator.pop(c, e.layout.copy())),
        ]),
      ),
    );
    if (preset == null) return;
    final name = await _askName('Template ${e.layouts.length + 1}');
    preset.name = (name == null || name.isEmpty) ? 'Template ${e.layouts.length + 1}' : name;
    setState(() => e.layouts.add(preset));
    await EventStore.instance.save();
    await _edit(e.layouts.length - 1);
  }

  Future<void> _menu(int i, String action) async {
    final l = e.layouts[i];
    switch (action) {
      case 'rename':
        final n = await _askName(l.name);
        if (n != null && n.isNotEmpty) setState(() => l.name = n);
      case 'duplicate':
        final c = l.copy()..name = '${l.name} copy';
        setState(() => e.layouts.insert(i + 1, c));
      case 'delete':
        if (e.layouts.length == 1) return;
        setState(() {
          e.layouts.removeAt(i);
          e.activeLayout = 0;
        });
    }
    await EventStore.instance.save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Templates')),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add template')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            e.layouts.length > 1
                ? 'Guests will choose one of these ${e.layouts.length} templates after tapping Start.'
                : 'Add a second template to let guests choose.',
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.62),
            itemCount: e.layouts.length,
            itemBuilder: (_, i) {
              final l = e.layouts[i];
              return Card(
                color: const Color(0xFF2A2A31),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _edit(i),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: FutureBuilder<Uint8List>(
                          future: _thumb(l),
                          builder: (_, snap) => snap.hasData
                              ? Image.memory(snap.data!, fit: BoxFit.contain)
                              : const Center(child: CircularProgressIndicator()),
                        ),
                      ),
                    ),
                    Row(children: [
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text('${l.paper.name} · ${l.shotCount} shot(s)',
                              style: const TextStyle(fontSize: 12, color: Colors.white60)),
                        ]),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (a) => _menu(i, a),
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'rename', child: Text('Rename')),
                          const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                          if (e.layouts.length > 1) const PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ]),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
