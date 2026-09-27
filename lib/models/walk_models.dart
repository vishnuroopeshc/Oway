import 'package:latlong2/latlong.dart';

class SavedRoute {
  final int? id;
  final List<LatLng> points;
  final int startTime;
  final int endTime;
  final int elapsedSeconds;
  final int steps;
  final double newAreaKm;

  SavedRoute({
    this.id,
    required this.points,
    required this.startTime,
    required this.endTime,
    required this.elapsedSeconds,
    required this.steps,
    required this.newAreaKm,
  });
}

class DiscoveryPoint {
  final int? id;
  final int? routeId;
  final LatLng position;
  final int timestamp;

  DiscoveryPoint({
    this.id,
    this.routeId,
    required this.position,
    required this.timestamp,
  });
}

class WalkSummary {
  final int elapsedSeconds;
  final int steps;
  final double newAreaKm;
  final double distanceKm;
  final List<LatLng> routePoints;

  /// One entry per consecutive pair in [routePoints]: true when that segment
  /// first crossed into never-before-visited territory.
  final List<bool> segmentIsNew;

  WalkSummary({
    required this.elapsedSeconds,
    required this.steps,
    required this.newAreaKm,
    required this.distanceKm,
    required this.routePoints,
    required this.segmentIsNew,
  });
}
