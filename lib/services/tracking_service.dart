import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum LocationAccessResult { granted, serviceDisabled, denied, deniedForever }

class TrackingService {
  StreamSubscription<Position>? _positionSub;

  static const double newAreaThresholdMeters = 18.0;
  static const double strideLengthMeters = 0.75;

  Future<LocationAccessResult> ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return LocationAccessResult.serviceDisabled;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      return LocationAccessResult.denied;
    }
    if (permission == LocationPermission.deniedForever) {
      return LocationAccessResult.deniedForever;
    }
    return LocationAccessResult.granted;
  }

  void start({required void Function(Position position) onPosition}) {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(onPosition);
  }

  void stop() {
    _positionSub?.cancel();
    _positionSub = null;
  }

  /// Minimum distance in meters from [point] to any point in [pool].
  static double minDistanceTo(LatLng point, Iterable<LatLng> pool) {
    var best = double.infinity;
    for (final p in pool) {
      final d = Geolocator.distanceBetween(
        point.latitude,
        point.longitude,
        p.latitude,
        p.longitude,
      );
      if (d < best) best = d;
    }
    return best;
  }
}
