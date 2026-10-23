import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/root_page.dart';
import 'tv/tv_mode.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // TV 检测需在首帧前完成: TV 模式强制横屏 (对照原版 NovaTV 各 Activity
  // android:screenOrientation="sensorLandscape"; 手机模式不限制方向).
  await TvMode.init();
  if (TvMode.isTV.value) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
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
      // 设置页切换 TV 模式 (自动/开/关) 后整树重建, 手机/TV 布局即时互换.
      home: ValueListenableBuilder<bool>(
        valueListenable: TvMode.isTV,
        builder: (_, __, ____) => const RootPage(),
      ),
    );
  }
}
