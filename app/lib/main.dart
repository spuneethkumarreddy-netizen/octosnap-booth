import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'canon_helper.dart';
import 'kiosk.dart';
import 'models.dart';
import 'screens/events_screen.dart';
import 'storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EventStore.instance.load();
  await Kiosk.init();
  // Windows: start the Canon EDSDK helper (OctoSnapCamera.exe next to the app) in the background.
  if (Platform.isWindows) unawaited(CanonHelper.instance.ensureRunning());
  runApp(const OctoSnapBoothApp());
}

class OctoSnapBoothApp extends StatelessWidget {
  const OctoSnapBoothApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: 'Poppins',
      colorScheme: ColorScheme.fromSeed(
        seedColor: brandOrange,
        primary: brandOrange,
        brightness: Brightness.dark,
        surface: brandCharcoal,
      ),
      scaffoldBackgroundColor: brandCharcoal,
    );
    return MaterialApp(
      title: 'OctoSnap Booth',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        appBarTheme: const AppBarTheme(backgroundColor: brandCharcoal, centerTitle: false),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(backgroundColor: brandOrange, foregroundColor: Colors.white),
        ),
      ),
      home: const EventsScreen(),
    );
  }
}
