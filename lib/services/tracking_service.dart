import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum LocationAccessResult { granted, serviceDisabled, denied, deniedForever }

/// A spatial index of "explored" GPS nodes: each added point creates a
/// [TrackingService.nodeRadiusMeters]-radius circle of explored ground.
/// [isExplored] does a real geographic-distance check against nearby nodes
/// (never a coordinate or grid-cell equality check, since GPS readings for
/// the same physical spot are never bit-identical) — nodes are only
/// bucketed internally so that check doesn't have to scan every node ever
/// recorded.
class ExploredNodeIndex {
  final Map<String, List<LatLng>> _buckets = {};

  void add(LatLng point) {
    final key = TrackingService._bucketKeyFor(point);
    _buckets.putIfAbsent(key, () => []).add(point);
  }

  void addAll(Iterable<LatLng> points) {
    for (final point in points) {
      add(point);
    }
  }

  void clear() => _buckets.clear();

  /// True if [point] falls within [TrackingService.nodeRadiusMeters] of any
  /// node added to this index.
  bool isExplored(LatLng point) {
    for (final key in TrackingService._candidateBucketKeys(point)) {
      final bucket = _buckets[key];
      if (bucket == null) continue;
      for (final node in bucket) {
        final distance = Geolocator.distanceBetween(
          point.latitude,
          point.longitude,
          node.latitude,
          node.longitude,
        );
        if (distance <= TrackingService.nodeRadiusMeters) return true;
      }
    }
    return false;
  }
}

class TrackingService {
  StreamSubscription<Position>? _positionSub;

  static const double strideLengthMeters = 0.75;

  /// Radius of the circular "explored" area around each saved GPS node, in
  /// meters. A point is considered already-explored if it falls within this
  /// radius of any node saved on a past (or earlier-this-walk) visit.
  static const double nodeRadiusMeters = 10.0;

  /// Bucket size used only to index nodes for fast lookup (not the
  /// explored radius itself). Must be at least 2x [nodeRadiusMeters] so
  /// that checking a point's own bucket plus its 8 neighbors is guaranteed
  /// to cover every node that could be within range.
  static const double _bucketSizeMeters = 20.0;

  static const double _metersPerDegreeLat = 111320.0;

  /// The spatial-index bucket key [point] falls into. Longitude spacing is
  /// corrected for latitude so buckets stay roughly square away from the
  /// equator. This is purely a lookup-performance detail — the actual
  /// explored/new decision is a real geographic-distance check against
  /// [nodeRadiusMeters], never bucket membership.
  static String _bucketKeyFor(LatLng point) {
    final metersPerDegreeLng =
        _metersPerDegreeLat * cos(point.latitude * pi / 180);
    final latStep = _bucketSizeMeters / _metersPerDegreeLat;
    final lngStep = _bucketSizeMeters / metersPerDegreeLng;
    final row = (point.latitude / latStep).floor();
    final col = (point.longitude / lngStep).floor();
    return '$row:$col';
  }

  /// [point]'s own bucket plus its 8 neighbors — the full set of buckets
  /// that could contain a node within [nodeRadiusMeters] of [point].
  static List<String> _candidateBucketKeys(LatLng point) {
    final metersPerDegreeLng =
        _metersPerDegreeLat * cos(point.latitude * pi / 180);
    final latStep = _bucketSizeMeters / _metersPerDegreeLat;
    final lngStep = _bucketSizeMeters / metersPerDegreeLng;
    final row = (point.latitude / latStep).floor();
    final col = (point.longitude / lngStep).floor();
    return [
      for (var dr = -1; dr <= 1; dr++)
        for (var dc = -1; dc <= 1; dc++) '${row + dr}:${col + dc}',
    ];
  }

  /// Points sampled roughly every [nodeRadiusMeters] along the segment from
  /// [from] to [to], so a fast-moving or low-frequency GPS fix doesn't skip
  /// over ground it actually passed through without placing/checking nodes
  /// there.
  static List<LatLng> sampleAlong(LatLng from, LatLng to) {
    final distance = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
    if (distance <= nodeRadiusMeters) return [to];
    final steps = (distance / nodeRadiusMeters).ceil();
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

  /// Warms up the GPS before a walk starts: a phone's very first fix after
  /// being idle is often a noisy, low-accuracy "cold" reading, which would
  /// otherwise become the walk's inaccurate starting point. This requests
  /// high-accuracy updates and collects fixes for a few seconds, returning
  /// as soon as one is accurate enough (or the most accurate one seen, once
  /// [maxWait] runs out).
  Future<Position?> acquireAccurateFix({
    Duration maxWait = const Duration(seconds: 6),
    double goodAccuracyMeters = 15,
  }) async {
    final completer = Completer<Position?>();
    Position? best;
    StreamSubscription<Position>? sub;
    Timer? timeout;

    void finish(Position? result) {
      if (completer.isCompleted) return;
      completer.complete(result);
      sub?.cancel();
      timeout?.cancel();
    }

    sub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
          ),
        ).listen(
          (position) {
            if (best == null || position.accuracy < best!.accuracy) {
              best = position;
            }
            if (position.accuracy <= goodAccuracyMeters) {
              finish(position);
            }
          },
          onError: (_) => finish(best),
          cancelOnError: true,
        );

    timeout = Timer(maxWait, () => finish(best));

    return completer.future;
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
