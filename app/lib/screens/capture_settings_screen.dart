import 'package:flutter/material.dart';

import '../models.dart';

class CaptureSettingsScreen extends StatefulWidget {
  final BoothEvent event;
  const CaptureSettingsScreen({super.key, required this.event});
  @override
  State<CaptureSettingsScreen> createState() => _CaptureSettingsScreenState();
}

class _CaptureSettingsScreenState extends State<CaptureSettingsScreen> {
  CaptureSettings get s => widget.event.capture;

  Widget _slider(String label, double value, double min, double max, int div, String unit, ValueChanged<double> f) =>
      ListTile(
        title: Text(label),
        subtitle: Slider(min: min, max: max, divisions: div, value: value.clamp(min, max), onChanged: (v) => setState(() => f(v))),
        trailing: Text('${value % 1 == 0 ? value.toInt() : value.toStringAsFixed(1)} $unit',
            style: const TextStyle(fontWeight: FontWeight.w700, color: brandOrange)),
      );

  Future<void> _setPin() async {
    final ctl = TextEditingController(text: s.exitPin);
    final pin = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Exit PIN'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(hintText: '4–6 digits, empty = no PIN'),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save'))],
      ),
    );
    if (pin != null) setState(() => s.exitPin = pin.replaceAll(RegExp(r'[^0-9]'), ''));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture settings')),
      body: ListView(padding: const EdgeInsets.all(8), children: [
        ListTile(
          leading: const Icon(Icons.photo_library, color: brandOrange),
          title: Text('Shots per session: ${widget.event.layout.shotCount}'),
          subtitle: const Text('Comes from the highest photo number in the photo layout.'),
        ),
        const Divider(),
        SwitchListTile(
          secondary: const Icon(Icons.directions_walk, color: brandOrange),
          title: const Text('Roaming (instant)'),
          subtitle: const Text('No welcome screen or countdown. Live view full screen; tap anywhere, '
              'press the camera shutter, a clicker or a volume key to take the photo.'),
          value: s.roaming,
          onChanged: (v) => setState(() => s.roaming = v),
        ),
        if (s.roaming)
          SwitchListTile(
            title: const Text('Auto-accept / no review'),
            subtitle: const Text('Roaming: skip Retake/Keep and go straight to the sheet + print'),
            value: s.autoAccept,
            onChanged: (v) => setState(() => s.autoAccept = v),
          ),
        SwitchListTile(
          secondary: const Icon(Icons.view_column, color: brandOrange),
          title: const Text('Pair mode: next 2 shots on one sheet'),
          subtitle: Text(widget.event.layout.shotCount == 1 &&
                  widget.event.layout.elements.where((x) => x.type == ElementType.photo).length >= 2
              ? 'Template "${widget.event.layout.name}": first shot waits, second shot completes the sheet and prints. '
                  'Operator can force-print a single from the booth.'
              : 'Needs a 1-shot template with 2 or more photo boxes (e.g. Magnets 2x).'),
          value: widget.event.layout.pairMode,
          onChanged: (v) => setState(() => widget.event.layout.pairMode = v),
        ),
        const Divider(),
        _slider('First countdown', s.firstCountdown.toDouble(), 0, 10, 10, 's', (v) => s.firstCountdown = v.round()),
        _slider('Countdown for next shots', s.countdown.toDouble(), 0, 10, 10, 's', (v) => s.countdown = v.round()),
        _slider('Show each photo for', s.displaySeconds, 0, 6, 12, 's', (v) => s.displaySeconds = v),
        _slider('Delay between shots', s.delayBetween, 0, 5, 10, 's', (v) => s.delayBetween = v),
        _slider('Show final sheet for', s.finalDisplaySeconds.toDouble(), 3, 60, 57, 's', (v) => s.finalDisplaySeconds = v.round()),
        SwitchListTile(
          title: const Text('Allow retake'),
          subtitle: const Text('Guest can Retake or Keep each photo'),
          value: s.allowRetake,
          onChanged: (v) => setState(() => s.allowRetake = v),
        ),
        SwitchListTile(
          title: const Text('Crop guide on live view'),
          subtitle: const Text('Darkens what will be cut off, so guests stand inside the magnet'),
          value: s.showCropGuide,
          onChanged: (v) => setState(() => s.showCropGuide = v),
        ),
        SwitchListTile(
          title: const Text('Sounds'),
          subtitle: const Text('Countdown ticks and shutter click'),
          value: s.sounds,
          onChanged: (v) => setState(() => s.sounds = v),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.lock, color: brandOrange),
          title: const Text('Operator exit PIN'),
          subtitle: Text(s.exitPin.isEmpty ? 'Off: anyone can exit the booth' : 'On: PIN needed to exit the booth'),
          trailing: TextButton(onPressed: _setPin, child: Text(s.exitPin.isEmpty ? 'Set' : 'Change')),
        ),
      ]),
    );
  }
}
