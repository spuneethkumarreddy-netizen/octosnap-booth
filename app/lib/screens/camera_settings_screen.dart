import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../dslr.dart';
import '../models.dart';

String cameraLabel(CameraDescription c) {
  final dir = switch (c.lensDirection) {
    CameraLensDirection.front => 'Front',
    CameraLensDirection.back => 'Back',
    CameraLensDirection.external => 'External / USB',
  };
  return '$dir · ${c.name}';
}

class CameraSettingsScreen extends StatefulWidget {
  final BoothEvent event;
  const CameraSettingsScreen({super.key, required this.event});
  @override
  State<CameraSettingsScreen> createState() => _CameraSettingsScreenState();
}

class _CameraSettingsScreenState extends State<CameraSettingsScreen> {
  String? _dslrStatus;

  Future<void> _testDslr() async {
    if (!Dslr.supported) {
      setState(() => _dslrStatus = 'Windows DSLR support coming next');
      return;
    }
    setState(() => _dslrStatus = 'Searching…');
    try {
      final name = await Dslr.connect();
      if (mounted) setState(() => _dslrStatus = '✓ $name connected. Checking live view…');
      var live = 'live view not ready';
      try {
        await Dslr.startLiveView();
        for (var i = 0; i < 15; i++) {
          final f = await Dslr.liveFrame();
          if (f != null && f.isNotEmpty) {
            live = 'live view OK';
            break;
          }
          await Future.delayed(const Duration(milliseconds: 200));
        }
      } catch (e) {
        live = 'live view error: ${e is PlatformException ? e.message : e}';
      }
      await Dslr.close();
      if (mounted) setState(() => _dslrStatus = '✓ $name connected, $live');
    } catch (err) {
      final msg = err is PlatformException ? err.message : '$err';
      if (mounted) setState(() => _dslrStatus = 'Not connected: $msg');
    }
  }

  List<CameraDescription> cameras = [];
  CameraController? ctl;
  String? error;
  CameraSettings get s => widget.event.camera;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => error = 'No camera found on this device.');
        return;
      }
      s.cameraName ??= cameras.first.name;
      await _startPreview();
    } catch (e) {
      setState(() => error = 'Camera error: $e');
    }
  }

  Future<void> _startPreview() async {
    final desc = cameras.firstWhere((c) => c.name == s.cameraName, orElse: () => cameras.first);
    final old = ctl;
    ctl = null;
    setState(() {});
    await old?.dispose();
    final c = CameraController(desc, ResolutionPreset.max, enableAudio: false);
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        ctl = c;
        error = null;
      });
    } catch (e) {
      setState(() => error = 'Could not open camera: $e');
    }
  }

  @override
  void dispose() {
    ctl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ctl;
    Widget preview = const Center(child: CircularProgressIndicator());
    if (error != null) preview = Center(child: Text(error!, textAlign: TextAlign.center));
    if (c != null && c.value.isInitialized) {
      preview = RotatedBox(
        quarterTurns: s.quarterTurns,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(s.mirrorPreview ? -1 : 1, 1, 1),
          child: CameraPreview(c),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Camera settings')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Text('CAMERA SOURCE', style: TextStyle(color: Colors.white54, letterSpacing: 2)),
        RadioGroup<CameraSource>(
          groupValue: s.source,
          onChanged: (v) => setState(() => s.source = v!),
          child: const Column(children: [
            RadioListTile(value: CameraSource.builtIn, title: Text('Built-in / webcam')),
            RadioListTile(
              value: CameraSource.usbDslr,
              title: Text('USB DSLR (Canon EOS R10 via USB-C)'),
              subtitle: Text('Android: USB-C cable / OTG. If not found, booth uses the built-in camera.'),
            ),
          ]),
        ),
        if (s.source == CameraSource.usbDslr)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FilledButton.icon(
                onPressed: _testDslr,
                icon: const Icon(Icons.usb),
                label: Text(_dslrStatus ?? 'Test DSLR connection'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Camera lo: Image quality = JPEG (L), Auto power off = Disable, Wi-Fi off. '
                'Camera ON chesi cable connect cheyyandi, permission adigithe Allow nokkandi.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ]),
          ),
        if (cameras.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: cameras.any((x) => x.name == s.cameraName) ? s.cameraName : cameras.first.name,
            decoration: const InputDecoration(labelText: 'Camera'),
            items: cameras.map((x) => DropdownMenuItem(value: x.name, child: Text(cameraLabel(x)))).toList(),
            onChanged: (v) {
              s.cameraName = v;
              _startPreview();
            },
          ),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 4 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(color: Colors.black, child: Center(child: preview)),
          ),
        ),
        SwitchListTile(
          title: const Text('Mirror live preview'),
          subtitle: const Text('Guests see themselves like a mirror'),
          value: s.mirrorPreview,
          onChanged: (v) => setState(() => s.mirrorPreview = v),
        ),
        SwitchListTile(
          title: const Text('Mirror printed photo'),
          value: s.mirrorPhoto,
          onChanged: (v) => setState(() => s.mirrorPhoto = v),
        ),
        ListTile(
          title: const Text('Rotate camera'),
          subtitle: Text('${s.quarterTurns * 90}°'),
          trailing: IconButton(
            icon: const Icon(Icons.rotate_90_degrees_cw),
            onPressed: () => setState(() => s.quarterTurns = (s.quarterTurns + 1) % 4),
          ),
        ),
      ]),
    );
  }
}
