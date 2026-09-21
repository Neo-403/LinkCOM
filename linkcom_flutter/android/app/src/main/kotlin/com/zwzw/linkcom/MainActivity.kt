package com.zwzw.linkcom

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 两个原生桥:
//  linkcom/deeplink  深链: 把 linkcom:// 启动参数交给 Dart(冷启动 initialLink / 热启动 onNewIntent -> 'link')
//  linkcom/perm      BLE 运行时权限: Android12+ 需 BLUETOOTH_SCAN/CONNECT, 低版本扫描需定位权限
class MainActivity : FlutterActivity() {
    private val channelName = "linkcom/deeplink"
    private val permChannelName = "linkcom/perm"
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "requestBluetooth") {
                    result.success(requestBluetoothPermissions())
                } else if (call.method == "sdkInt") {
                    result.success(Build.VERSION.SDK_INT)
                } else {
                    result.notImplemented()
                }
            }
    }

    // 返回 true 表示权限已齐; false 表示已弹出申请(用户确认后再次调用即可)
    private fun requestBluetoothPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val missing = perms.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return true
        requestPermissions(missing.toTypedArray(), 1001)
        return false
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = intent.dataString ?: return
        pendingUri = uri
        channel?.invokeMethod("link", uri)
    }
}
