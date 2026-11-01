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
      ]),
    );
  }
}
