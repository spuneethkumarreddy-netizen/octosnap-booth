import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Persists events (with their layouts) and imported assets on the device.
class EventStore extends ChangeNotifier {
  EventStore._();
  static final EventStore instance = EventStore._();

  final List<BoothEvent> events = [];
  late Directory _root;
  bool loaded = false;

  Directory get root => _root;
  Directory get assetsDir => Directory('${_root.path}${Platform.pathSeparator}assets');
  Directory get photosDir => Directory('${_root.path}${Platform.pathSeparator}photos');

  File get _file => File('${_root.path}${Platform.pathSeparator}events.json');

  Future<void> load() async {
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory('${docs.path}${Platform.pathSeparator}OctoSnapBooth');
    await _root.create(recursive: true);
    await assetsDir.create(recursive: true);
    await photosDir.create(recursive: true);
    events.clear();
    if (await _file.exists()) {
      try {
        final list = jsonDecode(await _file.readAsString()) as List;
        events.addAll(list.map((e) => BoothEvent.fromJson(e as Map<String, dynamic>)));
      } catch (e) {
        debugPrint('Could not read events: $e');
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(events.map((e) => e.toJson()).toList()));
    await tmp.rename(_file.path);
    notifyListeners();
  }

  Future<BoothEvent> create(String name, PhotoLayout layout) async {
    final e = BoothEvent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      date: DateTime.now(),
      layout: layout,
    );
    events.insert(0, e);
    await save();
    return e;
  }

  Future<BoothEvent> duplicate(BoothEvent src) async {
    final j = src.toJson();
    j['id'] = DateTime.now().microsecondsSinceEpoch.toString();
    j['name'] = '${src.name} (copy)';
    final e = BoothEvent.fromJson(j);
    events.insert(events.indexOf(src) + 1, e);
    await save();
    return e;
  }

  Future<void> delete(BoothEvent e) async {
    events.remove(e);
    await save();
  }

  /// Copies an imported file (template PNG, logo) into app storage so it survives.
  Future<String> importAsset(String sourcePath) async {
    final name = sourcePath.split(RegExp(r'[\\/]')).last;
    final dest = File('${assetsDir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$name');
    await File(sourcePath).copy(dest.path);
    return dest.path;
  }

  Future<String> importBytes(List<int> bytes, String name) async {
    final dest = File('${assetsDir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$name');
    await dest.writeAsBytes(bytes);
    return dest.path;
  }
}
