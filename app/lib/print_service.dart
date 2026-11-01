import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show BuildContext;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'models.dart';

class PrintService {
  static Future<Uint8List> buildPdf(Uint8List png, PaperSize paper) async {
    final doc = pw.Document();
    final format = PdfPageFormat(paper.w * PdfPageFormat.inch, paper.h * PdfPageFormat.inch, marginAll: 0);
    final img = pw.MemoryImage(png);
    doc.addPage(pw.Page(
      pageFormat: format,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.SizedBox.expand(child: pw.Image(img, fit: pw.BoxFit.fill)),
    ));
    return doc.save();
  }

  /// Direct printing works on Windows/macOS when a printer was picked in Print setup.
  static bool get supportsDirectPrint => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<Printer?> pickPrinter(BuildContext context) => Printing.pickPrinter(context: context);

  /// Prints the sheet. On desktop with a saved printer it prints silently `copies` times;
  /// otherwise it opens the system print dialog (Android: Epson iPrint / Mopria service).
  static Future<bool> printSheet(Uint8List png, BoothEvent event) async {
    final pdf = await buildPdf(png, event.layout.paper);
    final ps = event.print;
    final format = PdfPageFormat(event.layout.paper.w * PdfPageFormat.inch,
        event.layout.paper.h * PdfPageFormat.inch, marginAll: 0);
    if (supportsDirectPrint && ps.printerUrl != null) {
      final printer = Printer(url: ps.printerUrl!, name: ps.printerName);
      var ok = true;
      for (var i = 0; i < ps.copies; i++) {
        ok = await Printing.directPrintPdf(printer: printer, onLayout: (_) async => pdf, format: format) && ok;
      }
      return ok;
    }
    return Printing.layoutPdf(onLayout: (_) async => pdf, name: 'OctoSnap ${event.name}', format: format);
  }
}
