import 'package:flutter/material.dart';

import '../models.dart';
import '../storage.dart';
import 'event_home_screen.dart';

class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final nameCtl = TextEditingController(text: 'New Event');
    var preset = 'magnets';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Create event'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'Event name'), autofocus: true),
              const SizedBox(height: 16),
              const Text('Start from'),
              RadioGroup<String>(
                groupValue: preset,
                onChanged: (v) => setS(() => preset = v!),
                child: const Column(children: [
                  RadioListTile(value: 'magnets', title: Text('6 fridge magnets (2x2) on 4x6')),
                  RadioListTile(value: 'single', title: Text('Single photo 4x6')),
                  RadioListTile(value: 'strip', title: Text('Photo strip 2x6 (3 shots)')),
                  RadioListTile(value: 'blank', title: Text('Blank 4x6')),
                ]),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final layout = switch (preset) {
      'single' => PhotoLayout.singlePhoto(),
      'strip' => PhotoLayout.strip3(),
      'blank' => PhotoLayout(paper: PaperSize.presets.first),
      _ => PhotoLayout.sixMagnets(),
    };
    final e = await EventStore.instance.create(nameCtl.text.trim().isEmpty ? 'New Event' : nameCtl.text.trim(), layout);
    if (context.mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => EventHomeScreen(event: e)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = EventStore.instance;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: brandOrange, borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: const Text('O', style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white)),
          ),
          const SizedBox(width: 12),
          const Text('OctoSnap Booth — Events'),
        ]),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: brandOrange,
        foregroundColor: Colors.white,
        onPressed: () => _create(context),
        icon: const Icon(Icons.add),
        label: const Text('Create event'),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (store.events.isEmpty) {
            return const Center(
              child: Text('No events yet.\nTap "Create event" to start.', textAlign: TextAlign.center),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: store.events.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final e = store.events[i];
              return Card(
                color: const Color(0xFF2A2A31),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: const Icon(Icons.photo_camera_back, color: brandOrange, size: 36),
                  title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                      '${e.layout.paper.name} · ${e.layout.elements.where((x) => x.type == ElementType.photo).length} photo boxes · ${e.layout.shotCount} shot(s)'),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EventHomeScreen(event: e))),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'dup') await store.duplicate(e);
                      if (v == 'del') {
                        if (!context.mounted) return;
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text('Delete "${e.name}"?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (yes == true) await store.delete(e);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'dup', child: Text('Duplicate')),
                      PopupMenuItem(value: 'del', child: Text('Delete')),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
