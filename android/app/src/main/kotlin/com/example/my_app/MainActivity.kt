package com.example.my_app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "trailwise/walk_tracking_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler {
            call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, WalkTrackingService::class.java).apply {
                        action = WalkTrackingService.ACTION_START
                        putExtra(WalkTrackingService.EXTRA_TITLE, call.argument<String>("title"))
                        putExtra(WalkTrackingService.EXTRA_TEXT, call.argument<String>("text"))
                    }
                    startServiceCompat(intent)
                    result.success(null)
                }
                "update" -> {
                    val intent = Intent(this, WalkTrackingService::class.java).apply {
                        action = WalkTrackingService.ACTION_UPDATE
                        putExtra(WalkTrackingService.EXTRA_TITLE, call.argument<String>("title"))
                        putExtra(WalkTrackingService.EXTRA_TEXT, call.argument<String>("text"))
                    }
                    startServiceCompat(intent)
                    result.success(null)
                }
                "stop" -> {
                    val intent = Intent(this, WalkTrackingService::class.java).apply {
                        action = WalkTrackingService.ACTION_STOP
                    }
                    startServiceCompat(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startServiceCompat(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
