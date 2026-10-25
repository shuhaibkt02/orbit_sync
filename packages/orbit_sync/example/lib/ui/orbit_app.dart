import 'package:flutter/material.dart';
import '../main.dart';
import 'apple_theme.dart';

/// Top-level MaterialApp configured with Apple design styling and dynamic theme modes.
class OrbitSyncExampleApp extends StatelessWidget {
  const OrbitSyncExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Orbit Sync',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        colorScheme: const ColorScheme.light(primary: AppleTheme.systemBlue, surface: Colors.white),
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(primary: AppleTheme.systemBlueDark, surface: Color(0xFF1C1C1E)),
        fontFamily: '.SF Pro Text',
        useMaterial3: true,
      ),
      home: const TaskScreen(),
    );
  }
}
