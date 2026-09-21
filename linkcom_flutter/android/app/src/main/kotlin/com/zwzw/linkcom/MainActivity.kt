package com.zwzw.linkcom

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 深链桥: 把 linkcom:// 启动参数交给 Dart 端(MethodChannel 'linkcom/deeplink')
//   Dart 冷启动调用 initialLink 取当前 intent 的 URI
//   已在运行时(launchMode=singleTop)走 onNewIntent, 通过 'link' 回调推给 Dart
class MainActivity : FlutterActivity() {
    private val channelName = "linkcom/deeplink"
    private var pendingUri: String? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            if (call.method == "initialLink") {
                result.success(pendingUri ?: intent?.dataString)
                pendingUri = null
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = intent.dataString ?: return
        pendingUri = uri
        channel?.invokeMethod("link", uri)
    }
}
