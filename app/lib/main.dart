import 'package:flutter/material.dart';

import 'models.dart';
import 'screens/events_screen.dart';
import 'storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EventStore.instance.load();
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
