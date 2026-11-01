import 'package:flutter/material.dart';

import '../models.dart';
import '../storage.dart';
import 'booth_screen.dart';
import 'camera_settings_screen.dart';
import 'gallery_screen.dart';
import 'capture_settings_screen.dart';
import 'layout_editor_screen.dart';
import 'print_setup_screen.dart';
import 'welcome_editor_screen.dart';

/// Customize / Launch hub for one event (mirrors LumaBooth's event page).
class EventHomeScreen extends StatefulWidget {
  final BoothEvent event;
  const EventHomeScreen({super.key, required this.event});
  @override
  State<EventHomeScreen> createState() => _EventHomeScreenState();
}

class _EventHomeScreenState extends State<EventHomeScreen> {
  Future<void> _open(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    await EventStore.instance.save();
    if (mounted) setState(() {});
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: widget.event.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Event name'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save'))],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      widget.event.name = name.trim();
      await EventStore.instance.save();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    Widget tile(IconData icon, String title, String sub, Widget screen) => Card(
          color: const Color(0xFF2A2A31),
          child: ListTile(
            leading: Icon(icon, color: brandOrange),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(sub),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(screen),
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(e.name),
        actions: [IconButton(onPressed: _rename, icon: const Icon(Icons.edit))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            height: 64,
            child: FilledButton.icon(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BoothScreen(event: e))),
              icon: const Icon(Icons.play_arrow, size: 32),
              label: const Text('LAUNCH BOOTH', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          tile(Icons.photo_library, 'Gallery', 'View, reprint and share this event\'s photos', GalleryScreen(event: e)),
          const SizedBox(height: 12),
          const Text('CUSTOMIZE', style: TextStyle(color: Colors.white54, letterSpacing: 2)),
          const SizedBox(height: 8),
          tile(Icons.waving_hand, 'Welcome screen', e.welcome.title, WelcomeEditorScreen(event: e)),
          tile(Icons.dashboard_customize, 'Photo layout',
              '${e.layout.paper.name} · ${e.layout.shotCount} shot(s)', LayoutEditorScreen(event: e)),
          tile(Icons.timer, 'Capture settings',
              'Countdown ${e.capture.firstCountdown}s / ${e.capture.countdown}s', CaptureSettingsScreen(event: e)),
          tile(Icons.photo_camera, 'Camera settings',
              e.camera.source == CameraSource.usbDslr ? 'USB DSLR' : (e.camera.cameraName ?? 'Built-in camera'),
              CameraSettingsScreen(event: e)),
          tile(Icons.print, 'Print setup',
              '${e.print.autoPrint ? 'Auto print' : 'Manual print'} · ${e.print.copies} cop${e.print.copies == 1 ? 'y' : 'ies'}',
              PrintSetupScreen(event: e)),
        ],
      ),
    );
  }
}
