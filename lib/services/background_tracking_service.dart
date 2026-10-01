import 'package:flutter/services.dart';

/// Talks to a plain native Android foreground service (see
/// `WalkTrackingService.kt`) that holds a persistent notification while a
/// walk is being tracked. Deliberately native-only — no second Flutter
/// engine — because a plugin that ran its own background engine (like
/// flutter_foreground_task) caused the geolocator plugin to deadlock the
/// main UI thread when two engines both touched it. GPS tracking itself
/// stays entirely in the app's single main engine; this class only ever
/// controls the notification.
class BackgroundTrackingService {
  BackgroundTrackingService._();

  static const _channel = MethodChannel('trailwise/walk_tracking_service');

  static Future<void> start({required String title, required String text}) {
    return _channel.invokeMethod('start', {'title': title, 'text': text});
  }

  static Future<void> update({required String title, required String text}) {
    return _channel.invokeMethod('update', {'title': title, 'text': text});
  }

  static Future<void> stop() {
    return _channel.invokeMethod('stop');
  }
}
