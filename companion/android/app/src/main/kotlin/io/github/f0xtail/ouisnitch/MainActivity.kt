package io.github.f0xtail.ouisnitch

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startService(Intent(this, KillTaskService::class.java))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Apps cannot switch Wi-Fi themselves since Android 10, so the phone
        // leak check opens the Wi-Fi panel for the user to do it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "io.github.f0xtail.ouisnitch/settings").setMethodCallHandler { call, result ->
            if (call.method == "openWifiPanel") {
                val action = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS
                startActivity(Intent(action))
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
