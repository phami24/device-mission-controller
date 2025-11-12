import 'package:flutter/material.dart';
import 'screens/mission_list_screen.dart';
import 'screens/compass_screen.dart';
// flight session removed; connect/send mission directly from compass

void main() {
  runApp(const MapCompassApp());
}

class MapCompassApp extends StatelessWidget {
  const MapCompassApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Map Compass',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      initialRoute: '/',
      routes: {
        '/': (context) => const MissionListScreen(),
        '/compass': (context) => const CompassScreen(),
      },
    );
  }
}
