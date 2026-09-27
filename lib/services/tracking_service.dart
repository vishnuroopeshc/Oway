import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum LocationAccessResult { granted, serviceDisabled, denied, deniedForever }

class TrackingService {
  StreamSubscription<Position>? _positionSub;

  static const double strideLengthMeters = 0.75;

  /// Size of one "explored" grid cell, in meters. GPS points are quantized
  /// into cells rather than compared pairwise, so a newly walked road reads
  /// as a continuous revealed band instead of scattered threshold dots.
  static const double cellSizeMeters = 20.0;

  static const double _metersPerDegreeLat = 111320.0;

  /// The grid-cell key [point] falls into. Longitude spacing is corrected
  /// for latitude so cells stay roughly square away from the equator.
  static String cellKeyFor(LatLng point) {
    final metersPerDegreeLng = _metersPerDegreeLat * cos(point.latitude * pi / 180);
    final latStep = cellSizeMeters / _metersPerDegreeLat;
    final lngStep = cellSizeMeters / metersPerDegreeLng;
    final row = (point.latitude / latStep).floor();
    final col = (point.longitude / lngStep).floor();
    return '$row:$col';
  }

  /// Points sampled roughly every [cellSizeMeters] along the segment from
  /// [from] to [to], so a fast-moving or low-frequency GPS fix doesn't skip
  /// over grid cells it actually passed through.
  static List<LatLng> sampleAlong(LatLng from, LatLng to) {
    final distance = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
    if (distance <= cellSizeMeters) return [to];
    final steps = (distance / cellSizeMeters).ceil();
    return [
      for (var i = 1; i <= steps; i++)
        LatLng(
          from.latitude + (to.latitude - from.latitude) * i / steps,
          from.longitude + (to.longitude - from.longitude) * i / steps,
        ),
    ];
  }

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
}
