import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/root_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const NovaBoxApp());
}

class NovaBoxApp extends StatelessWidget {
  const NovaBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NovaBox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey, brightness: Brightness.dark),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const RootPage(),
    );
  }
}
