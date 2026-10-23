package com.novabox.flutter

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        com.novabox.engine.SpiderEngine.bind(flutterEngine.dartExecutor.binaryMessenger)
    }
}
