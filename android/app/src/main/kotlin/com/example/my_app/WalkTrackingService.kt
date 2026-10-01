package com.example.my_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Plain Android foreground service that only holds a persistent
 * notification while a walk is being tracked. Deliberately does NOT run any
 * Dart/Flutter code of its own (no second Flutter engine) — GPS tracking
 * stays entirely in the app's single main engine. Two engines both touching
 * the geolocator plugin was what caused the ANR freeze with the
 * plugin-based approach this replaces.
 */
class WalkTrackingService : Service() {

    companion object {
        const val CHANNEL_ID = "trailwise_tracking"
        const val NOTIFICATION_ID = 300

        const val ACTION_START = "com.example.my_app.action.START_TRACKING"
        const val ACTION_UPDATE = "com.example.my_app.action.UPDATE_TRACKING"
        const val ACTION_STOP = "com.example.my_app.action.STOP_TRACKING"

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> start(intent)
            ACTION_UPDATE -> update(intent)
            ACTION_STOP -> stop()
        }
        return START_NOT_STICKY
    }

    private fun start(intent: Intent) {
        ensureChannel()
        val notification = buildNotification(
            intent.getStringExtra(EXTRA_TITLE) ?: "Oway",
            intent.getStringExtra(EXTRA_TEXT) ?: "Tracking your walk",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun update(intent: Intent) {
        val notification = buildNotification(
            intent.getStringExtra(EXTRA_TITLE) ?: "Oway",
            intent.getStringExtra(EXTRA_TEXT) ?: "Tracking your walk",
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, notification)
    }

    private fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Walk tracking",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Shown while Oway is tracking a walk."
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String): Notification {
        val openAppIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentIntent)
            .build()
    }
}
