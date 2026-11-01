import 'package:flutter/material.dart';

import '../compositor.dart';
import '../models.dart';
import '../print_service.dart';

class PrintSetupScreen extends StatefulWidget {
  final BoothEvent event;
  const PrintSetupScreen({super.key, required this.event});
  @override
  State<PrintSetupScreen> createState() => _PrintSetupScreenState();
}

class _PrintSetupScreenState extends State<PrintSetupScreen> {
  PrintSettings get s => widget.event.print;
  bool busy = false;

  Future<void> _pick() async {
    final p = await PrintService.pickPrinter(context);
    if (p != null) {
      setState(() {
        s.printerUrl = p.url;
        s.printerName = p.name;
      });
    }
  }

  Future<void> _test() async {
    setState(() => busy = true);
    try {
      final png = await SheetCompositor.compose(event: widget.event, shots: const []);
      await PrintService.printSheet(png, widget.event);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Print failed: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final paper = widget.event.layout.paper;
    return Scaffold(
      appBar: AppBar(title: const Text('Print setup')),
      body: ListView(padding: const EdgeInsets.all(8), children: [
        ListTile(
          leading: const Icon(Icons.description, color: brandOrange),
          title: Text('Paper: ${paper.name} (${paper.w}" x ${paper.h}")'),
          subtitle: const Text('Epson L8050: load 4x6 photo paper, borderless on.'),
        ),
        SwitchListTile(
          title: const Text('Auto print'),
          subtitle: Text(PrintService.supportsDirectPrint
              ? 'Prints straight to the chosen printer after each session'
              : 'Opens the Android print screen automatically after each session'),
          value: s.autoPrint,
          onChanged: (v) => setState(() => s.autoPrint = v),
        ),
        ListTile(
          title: const Text('Copies'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(onPressed: s.copies > 1 ? () => setState(() => s.copies--) : null, icon: const Icon(Icons.remove)),
            Text('${s.copies}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            IconButton(onPressed: s.copies < 10 ? () => setState(() => s.copies++) : null, icon: const Icon(Icons.add)),
          ]),
        ),
        if (PrintService.supportsDirectPrint)
          ListTile(
            title: const Text('Printer'),
            subtitle: Text(s.printerName ?? 'Not chosen — print dialog will open'),
            trailing: OutlinedButton(onPressed: _pick, child: const Text('Choose')),
          )
        else
          const ListTile(
            title: Text('Printer'),
            subtitle: Text('Android: install "Epson Print Enabler" / Mopria from Play Store, then pick Epson L8050 in the print screen.'),
          ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: busy ? null : _test,
            icon: const Icon(Icons.print),
            label: Text(busy ? 'Preparing…' : 'Test print (layout without photos)'),
          ),
        ),
      ]),
    );
  }
}
