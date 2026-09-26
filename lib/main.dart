import 'package:flutter/material.dart';
import 'screens/splash_screen.dart';

void main() {
  runApp(const TrailwiseApp());
}

class TrailwiseApp extends StatelessWidget {
  const TrailwiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trailwise',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A6741),
        ),
        fontFamily: 'Roboto',
      ),
      home: const SplashScreen(),
    );
  }
}