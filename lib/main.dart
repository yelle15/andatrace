import 'package:flutter/material.dart';
import 'ui/digitalization_screen.dart';

void main() {
  runApp(const AndaTraceApp());
}

class AndaTraceApp extends StatelessWidget {
  const AndaTraceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AndaTrace',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const DigitalizationScreen(),
    );
  }
}
