import 'dart:io';

import 'package:flutter/material.dart';

import '../models.dart';
import '../print_service.dart';
import '../storage.dart';

/// Every sheet made at this event: view, reprint, share, delete.
class GalleryScreen extends StatefulWidget {
  final BoothEvent event;
  const GalleryScreen({super.key, required this.event});
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<File> sheets = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await EventStore.instance.sheetsFor(widget.event);
    if (mounted) {
      setState(() {
        sheets = list;
        loading = false;
      });
    }
  }

  Future<void> _open(File f) async {
    final changed = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => _SheetViewer(event: widget.event, file: f)));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final paper = widget.event.layout.paper;
    return Scaffold(
      appBar: AppBar(title: Text('Gallery · ${sheets.length}')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : sheets.isEmpty
              ? const Center(child: Text('No photos yet. Launch the booth to start.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(10),
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: paper.w / paper.h,
                  ),
                  itemCount: sheets.length,
                  itemBuilder: (_, i) => InkWell(
                    onTap: () => _open(sheets[i]),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(sheets[i], fit: BoxFit.cover, cacheWidth: 400),
                    ),
                  ),
                ),
    );
  }
}

class _SheetViewer extends StatefulWidget {
  final BoothEvent event;
  final File file;
  const _SheetViewer({required this.event, required this.file});
  @override
  State<_SheetViewer> createState() => _SheetViewerState();
}

class _SheetViewerState extends State<_SheetViewer> {
  bool busy = false;

  Future<void> _run(Future<void> Function() job, String fail) async {
    setState(() => busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$fail: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this photo?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    await EventStore.instance.deleteSheet(widget.file);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.file.path.split(RegExp(r'[\\/]')).last.replaceAll('.png', '.pdf');
    return Scaffold(
      appBar: AppBar(actions: [IconButton(onPressed: busy ? null : _delete, icon: const Icon(Icons.delete_outline))]),
      body: Column(children: [
        Expanded(child: Padding(padding: const EdgeInsets.all(16), child: Image.file(widget.file, fit: BoxFit.contain))),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => _run(() async {
                              await PrintService.printSheet(await widget.file.readAsBytes(), widget.event);
                            }, 'Print failed'),
                    icon: const Icon(Icons.print),
                    label: const Text('REPRINT'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => _run(() async {
                              await PrintService.share(await widget.file.readAsBytes(), widget.event, name);
                            }, 'Share failed'),
                    icon: const Icon(Icons.share),
                    label: const Text('SHARE'),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
