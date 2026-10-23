package com.novabox.flutter

import android.content.Context
import android.content.res.Configuration
import android.app.UiModeManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        com.novabox.engine.SpiderEngine.bind(flutterEngine.dartExecutor.binaryMessenger)

        // TV 检测通道 (lib/tv/tv_mode.dart): 同一 APK 区分手机 / 电视布局.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "novabox/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTV" -> result.success(isTv())
                    else -> result.notImplemented()
                }
            }
    }

    /// 判定当前是否运行在 TV 设备:
    /// 1) leanback feature (Android TV);
    /// 2) UI_MODE_TYPE_TELEVISION (电视盒子常伪装 touchscreen, 但 uiMode 仍是 TV).
    private fun isTv(): Boolean {
        val pm = packageManager
        if (pm.hasSystemFeature("android.software.leanback")) return true
        val uiMode = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
    }
}
