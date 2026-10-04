import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import '../models/walk_models.dart';
import '../services/background_tracking_service.dart';
import '../services/database_helper.dart';
import '../services/location_name_service.dart';
import '../services/tracking_service.dart';
import '../services/weather_service.dart';
import '../theme/app_colors.dart';
import '../widgets/stat_column.dart';
import 'results_screen.dart';
import 'settings_screen.dart';

enum _MapStyle { terrain, streets, satellite, minimal }

extension on _MapStyle {
  String get label => switch (this) {
    _MapStyle.terrain => 'Terrain',
    _MapStyle.streets => 'Streets',
    _MapStyle.satellite => 'Satellite',
    _MapStyle.minimal => 'Minimal',
  };

  IconData get icon => switch (this) {
    _MapStyle.terrain => Icons.terrain,
    _MapStyle.streets => Icons.map_outlined,
    _MapStyle.satellite => Icons.satellite_alt,
    _MapStyle.minimal => Icons.location_city,
  };

  String get urlTemplate => switch (this) {
    _MapStyle.terrain => 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    _MapStyle.streets => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    _MapStyle.satellite => 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    _MapStyle.minimal => 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}',
  };

  /// Esri's light-gray canvas ships its labels as a separate overlay layer.
  String? get labelsUrlTemplate => this == _MapStyle.minimal
      ? 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Reference/MapServer/tile/{z}/{y}/{x}'
      : null;

  int get maxNativeZoom => this == _MapStyle.terrain ? 17 : 19;

  String get attribution => switch (this) {
    _MapStyle.terrain => '© OpenTopoMap (CC-BY-SA)',
    _MapStyle.streets => '© OpenStreetMap contributors',
    _MapStyle.satellite => '© Esri, Maxar, Earthstar Geographics',
    _MapStyle.minimal => '© Esri',
  };
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const LatLng _fallbackCenter = LatLng(37.7749, -122.4194);

  final MapController _mapController = MapController();
  final TrackingService _trackingService = TrackingService();

  /// Draws saved routes in progressively once the map/tiles are up, instead
  /// of popping the full path in the instant data loads.
  late final AnimationController _routeRevealController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _routeReveal = CurvedAnimation(
    parent: _routeRevealController,
    curve: Curves.easeOutCubic,
  );

  _MapStyle _mapStyle = _MapStyle.terrain;

  bool _loading = true;
  List<SavedRoute> _savedRoutes = [];

  WeatherDetails? _weatherDetails;
  String? _locationName;

  /// Always grabs a fresh live GPS fix first (falling back to the last
  /// known point only if that fails), so weather reflects wherever the
  /// user currently is standing — not a stale cached location.
  Future<void> _loadWeather() async {
    try {
      final permission = await Geolocator.checkPermission();
      final granted =
          permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      if (!granted) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;

      LatLng? point;
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
          ),
        ).timeout(const Duration(seconds: 8));
        point = LatLng(position.latitude, position.longitude);
      } catch (_) {
        point =
            _currentPosition ??
            (_savedRoutes.isNotEmpty && _savedRoutes.last.points.isNotEmpty
                ? _savedRoutes.last.points.last
                : null);
      }
      if (point == null) return;

      final results = await Future.wait([
        WeatherService.fetchDetails(point.latitude, point.longitude),
        LocationNameService.reverseGeocode(point.latitude, point.longitude),
      ]);
      if (!mounted) return;
      setState(() {
        _weatherDetails = results[0] as WeatherDetails?;
        _locationName = results[1] as String?;
      });
    } catch (_) {
      // Weather is a nice-to-have; fail silently.
    }
  }

  /// When set, the map only shows routes from this day instead of all of
  /// history. Picked from the History calendar; date part only.
  DateTime? _historyFilterDate;

  /// Explored-node index (see [ExploredNodeIndex]) built from every walk
  /// saved before this session started.
  ExploredNodeIndex _knownIndex = ExploredNodeIndex();

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<SavedRoute> get _visibleRoutes {
    final filter = _historyFilterDate;
    if (filter == null) return _savedRoutes;
    return [
      for (final r in _savedRoutes)
        if (_isSameDate(
          DateTime.fromMillisecondsSinceEpoch(r.startTime),
          filter,
        ))
          r,
    ];
  }

  DateTime _dateOnly(int millisecondsSinceEpoch) {
    final d = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
    return DateTime(d.year, d.month, d.day);
  }

  Set<DateTime> get _daysWithWalks => {
    for (final r in _savedRoutes) _dateOnly(r.startTime),
  };

  bool _isTracking = false;
  // True while warming up the GPS for a few seconds before a walk starts,
  // so the walk's first point isn't a noisy cold-start fix.
  bool _acquiringGps = false;
  Timer? _timer;
  DateTime? _walkStartTime;
  int _seconds = 0;
  int _steps = 0;
  double _distanceMeters = 0;

  // Real step counting from the phone's own step-counter sensor (the same
  // hardware/software pedometer native fitness apps use), rather than
  // estimating steps from GPS distance. [_stepBaseline] is the sensor's
  // cumulative count (since device boot) captured when a walk starts;
  // steps for this walk = latest reading - baseline. Falls back to the
  // distance estimate in [_onPosition] if the sensor is unavailable.
  StreamSubscription<StepCount>? _stepCountSub;
  int? _stepBaseline;
  bool _hasStepSensor = true;
  double _newAreaMeters = 0;
  LatLng? _currentPosition;
  final List<LatLng> _liveRoutePoints = [];
  final List<bool> _liveSegmentIsNew = [];
  final List<LatLng> _sessionDiscoveryPoints = [];

  /// Nodes placed during the walk in progress that the walker has since
  /// moved well away from, so looping back over them later in the same walk
  /// reads as already-explored without waiting for the walk to be saved.
  final ExploredNodeIndex _sessionIndex = ExploredNodeIndex();

  /// Nodes placed during this walk that the walker hasn't yet moved
  /// [_sessionNodeLeaveMeters] away from. GPS fixes land closer together
  /// (every 5-8m) than the explored radius (10m), so if fresh nodes counted
  /// immediately, every step onto brand-new ground would fall inside the
  /// circle the previous step just placed and show green instead of gold.
  /// Requiring the walker to actually leave a node first is what makes a
  /// later return a genuine revisit — and unlike a time or path-distance
  /// delay, standing still with GPS jitter never counts as leaving.
  final List<LatLng> _pendingSessionNodes = [];

  /// A fix that jumped more than [_jumpHoldMeters] from the last accepted
  /// one, held back until the next fix shows whether it was real movement
  /// (next fix agrees with it) or a one-off GPS spike (next fix doesn't).
  Position? _heldJump;
  static const double _jumpHoldMeters = 30.0;
  bool _wasInNewTerritory = false;

  // Debounce state for the live green/amber color: GPS jitter right at the
  // edge of an explored circle can flip the raw classification for a
  // single noisy point, so the displayed color only changes once a flip
  // repeats. A low-accuracy fix is ignored for classification entirely
  // (though its position still counts for distance/route) rather than
  // being allowed to start or continue a flip.
  bool _displayedIsNew = false;
  int _pendingFlipStreak = 0;
  static const double _maxTrustedAccuracyMeters = 25.0;

  // 2x the node radius: far enough that a fresh node can't still be within
  // radius of the walker's next few steps (even with GPS jitter), small
  // enough that a real U-turn starts reading green within a few meters.
  static const double _sessionNodeLeaveMeters =
      TrackingService.nodeRadiusMeters * 2;

  ExploredNodeIndex _buildExploredIndex(List<SavedRoute> routes) {
    final index = ExploredNodeIndex();
    for (final route in routes) {
      for (var i = 0; i < route.points.length; i++) {
        if (i == 0) {
          index.add(route.points[i]);
          continue;
        }
        index.addAll(
          TrackingService.sampleAlong(route.points[i - 1], route.points[i]),
        );
      }
    }
    return index;
  }

  String get _formattedTime {
    final m = (_seconds ~/ 60).toString();
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedData();
    _loadWeather();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trackingService.stop();
    _timer?.cancel();
    _stopStepCounting();
    _routeRevealController.dispose();
    super.dispose();
  }

  /// The first [t] fraction of [points], eased in so a saved route draws
  /// itself on rather than appearing all at once.
  List<LatLng> _revealed(List<LatLng> points, double t) {
    if (points.length < 2 || t >= 1) return points;
    final count = (points.length * t).ceil().clamp(2, points.length);
    return points.sublist(0, count);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Tracking used to be cancelled here on background/detach. Now the
    // foreground service (started alongside tracking) keeps the walk
    // recording and shows a persistent notification, so backgrounding the
    // app no longer interrupts it.
  }

  Future<void> _loadSavedData() async {
    final routes = await DatabaseHelper.instance.loadAllRoutes();
    if (!mounted) return;
    setState(() {
      _savedRoutes = routes;
      _knownIndex = _buildExploredIndex(routes);
      _loading = false;
    });
    if (routes.isNotEmpty && routes.last.points.isNotEmpty) {
      final target = routes.last.points.last;
      try {
        _mapController.move(target, 15);
      } catch (_) {
        // Map not laid out yet; ignore.
      }
    }
    // Give the base map tiles a beat to appear before the route draws on.
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _routeRevealController.forward(from: 0);
    });
  }

  void _abandonTracking() {
    _trackingService.stop();
    _timer?.cancel();
    _stopStepCounting();
    BackgroundTrackingService.stop();
    setState(() {
      _isTracking = false;
      _liveRoutePoints.clear();
      _liveSegmentIsNew.clear();
      _sessionDiscoveryPoints.clear();
      _sessionIndex.clear();
      _pendingSessionNodes.clear();
      _heldJump = null;
      _wasInNewTerritory = false;
      _displayedIsNew = false;
      _pendingFlipStreak = 0;
      _seconds = 0;
      _steps = 0;
      _distanceMeters = 0;
      _newAreaMeters = 0;
    });
  }

  /// Vibrates the phone's motor directly, bypassing the system "touch
  /// feedback" haptics toggle that [HapticFeedback] depends on (Samsung
  /// One UI in particular mutes HapticFeedback when that setting is off).
  /// Falls back to HapticFeedback if the device reports no vibrator.
  Future<void> _vibrate({required int durationMs}) async {
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(duration: durationMs);
        return;
      }
    } catch (_) {
      // Fall through to HapticFeedback below.
    }
    HapticFeedback.mediumImpact();
  }

  /// Starts reading the phone's built-in step-counter sensor for this walk.
  /// The sensor reports a running total since the device last booted, so
  /// [_stepBaseline] anchors it and every later reading is shown as
  /// `reading - baseline`. If the sensor/permission isn't available,
  /// [_onPosition]'s distance-based estimate is used instead.
  Future<void> _startStepCounting() async {
    _stepBaseline = null;
    _hasStepSensor = true;
    await _stepCountSub?.cancel();

    if (await Permission.activityRecognition.isDenied) {
      final status = await Permission.activityRecognition.request();
      if (!status.isGranted) {
        _hasStepSensor = false;
        return;
      }
    }

    _stepCountSub = Pedometer.stepCountStream.listen(
      (event) {
        _stepBaseline ??= event.steps;
        if (!mounted) return;
        setState(() {
          _steps = (event.steps - _stepBaseline!).clamp(0, 1 << 30);
        });
      },
      onError: (_) {
        _hasStepSensor = false;
      },
      cancelOnError: true,
    );
  }

  void _stopStepCounting() {
    _stepCountSub?.cancel();
    _stepCountSub = null;
    _stepBaseline = null;
  }

  Future<void> _onStartStopPressed() async {
    if (_isTracking) {
      await _confirmStop();
      return;
    }

    final result = await _trackingService.ensurePermission();
    if (result != LocationAccessResult.granted) {
      if (mounted) _showPermissionIssue(result);
      return;
    }

    setState(() => _acquiringGps = true);
    final startFix = await _trackingService.acquireAccurateFix();
    if (!mounted) return;
    setState(() => _acquiringGps = false);

    unawaited(_vibrate(durationMs: 40));

    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    await BackgroundTrackingService.start(
      title: 'Oway is tracking your walk',
      text: '0:00 · 0 steps · 0.00 km',
    );

    final startPoint = startFix != null
        ? LatLng(startFix.latitude, startFix.longitude)
        : null;

    setState(() {
      _isTracking = true;
      _liveRoutePoints.clear();
      _liveSegmentIsNew.clear();
      _sessionDiscoveryPoints.clear();
      _sessionIndex.clear();
      _pendingSessionNodes.clear();
      _heldJump = null;
      _wasInNewTerritory = false;
      _displayedIsNew = false;
      if (startPoint != null) {
        _currentPosition = startPoint;
        _liveRoutePoints.add(startPoint);
        if (!_knownIndex.isExplored(startPoint)) {
          _pendingSessionNodes.add(startPoint);
          // Start gold on unexplored ground rather than needing the
          // flip-debounce to catch up over the first couple of fixes.
          _displayedIsNew = true;
        }
      }
      _pendingFlipStreak = 0;
      _seconds = 0;
      _steps = 0;
      _distanceMeters = 0;
      _newAreaMeters = 0;
      _walkStartTime = DateTime.now();
    });

    _startStepCounting();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
      if (_seconds % 3 == 0) {
        BackgroundTrackingService.update(
          title: 'Oway is tracking your walk',
          text:
              '$_formattedTime · $_steps steps · '
              '${(_distanceMeters / 1000).toStringAsFixed(2)} km',
        );
      }
    });

    _trackingService.start(onPosition: _onPosition);
  }

  void _zoomBy(double delta) {
    try {
      final camera = _mapController.camera;
      final newZoom = (camera.zoom + delta).clamp(2.0, 18.0);
      _mapController.move(camera.center, newZoom);
    } catch (_) {
      // Map not ready yet; ignore.
    }
  }

  Future<void> _onLocateMePressed() async {
    final result = await _trackingService.ensurePermission();
    if (result != LocationAccessResult.granted) {
      if (mounted) _showPermissionIssue(result);
      return;
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final point = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() => _currentPosition = point);
      // Zoom in to a close, street-level view of the user's location; never
      // zoom back out if they're already closer than that.
      const locatedZoom = 17.0;
      final targetZoom = _mapController.camera.zoom < locatedZoom
          ? locatedZoom
          : _mapController.camera.zoom;
      _mapController.move(point, targetZoom);
      _loadWeather();
    } catch (_) {
      // Ignore transient location errors; the user can try again.
    }
  }

  void _onPosition(Position position) {
    final held = _heldJump;
    _heldJump = null;
    // The next fix carrying on from the held jump (rather than snapping back
    // toward where we were) means the jump was real movement — this also
    // keeps fast, steady movement with sparse fixes from stalling.
    if (held != null &&
        _liveRoutePoints.isNotEmpty &&
        _metersTo(LatLng(held.latitude, held.longitude), position) <
            _metersTo(_liveRoutePoints.last, position)) {
      _acceptPosition(held);
    }
    if (_liveRoutePoints.isNotEmpty &&
        _metersTo(_liveRoutePoints.last, position) > _jumpHoldMeters) {
      _heldJump = position;
      return;
    }
    _acceptPosition(position);
  }

  double _metersTo(LatLng a, Position b) => Geolocator.distanceBetween(
    a.latitude,
    a.longitude,
    b.latitude,
    b.longitude,
  );

  /// Moves this walk's pending nodes that the walker is now more than
  /// [_sessionNodeLeaveMeters] from into [_sessionIndex] (see
  /// [_pendingSessionNodes] for why they wait).
  void _promoteLeftSessionNodes(LatLng walker) {
    _pendingSessionNodes.removeWhere((node) {
      final left =
          Geolocator.distanceBetween(
            walker.latitude,
            walker.longitude,
            node.latitude,
            node.longitude,
          ) >
          _sessionNodeLeaveMeters;
      if (left) _sessionIndex.add(node);
      return left;
    });
  }

  void _acceptPosition(Position position) {
    final point = LatLng(position.latitude, position.longitude);
    var segmentDistance = 0.0;
    // Defaults to holding the current classification rather than flipping,
    // so an untrusted (low-accuracy) fix below can't move it on its own.
    var rawIsNew = _displayedIsNew;
    var segmentIsNew = false;
    final trustedFix = position.accuracy <= _maxTrustedAccuracyMeters;

    if (_liveRoutePoints.isNotEmpty) {
      final prev = _liveRoutePoints.last;
      segmentDistance = Geolocator.distanceBetween(
        prev.latitude,
        prev.longitude,
        point.latitude,
        point.longitude,
      );

      if (trustedFix) {
        _promoteLeftSessionNodes(point);
        // Walk the ground this segment actually crosses (not just its
        // endpoint) so a fast GPS jump can't skip over new territory.
        // Classification is a real geographic-distance check against each
        // node's explored circle — never raw coordinate comparison, since
        // two GPS readings of the same spot are never bit-identical.
        rawIsNew = false;
        for (final sample in TrackingService.sampleAlong(prev, point)) {
          final alreadyExplored =
              _knownIndex.isExplored(sample) ||
              _sessionIndex.isExplored(sample);
          if (!alreadyExplored) {
            _pendingSessionNodes.add(sample);
            rawIsNew = true;
          }
        }
      }

      // Debounce only the DISPLAYED color/stat: a single noisy or
      // low-accuracy GPS point right at the edge of an explored circle can
      // flip rawIsNew for one segment even though you haven't actually
      // crossed into new ground. Require the flip to repeat before it
      // actually shows on the map.
      if (rawIsNew == _displayedIsNew) {
        _pendingFlipStreak = 0;
      } else {
        _pendingFlipStreak++;
        if (_pendingFlipStreak >= 2) {
          _displayedIsNew = rawIsNew;
          _pendingFlipStreak = 0;
        }
      }
      segmentIsNew = _displayedIsNew;

      if (segmentIsNew) {
        _newAreaMeters += segmentDistance;
      }
    } else if (trustedFix && !_knownIndex.isExplored(point)) {
      _pendingSessionNodes.add(point);
    }

    final enteringNewTerritory = segmentIsNew && !_wasInNewTerritory;
    _wasInNewTerritory = segmentIsNew;

    setState(() {
      _distanceMeters += segmentDistance;
      // The real step count comes from the phone's step-counter sensor via
      // _startStepCounting(); this is only a fallback for devices/permission
      // states where that sensor isn't available.
      if (!_hasStepSensor) {
        _steps = (_distanceMeters / TrackingService.strideLengthMeters).round();
      }
      _currentPosition = point;
      _liveRoutePoints.add(point);
      if (_liveRoutePoints.length > 1) {
        _liveSegmentIsNew.add(segmentIsNew);
      }
      if (enteringNewTerritory) {
        _sessionDiscoveryPoints.add(point);
      }
    });

    try {
      _mapController.move(point, _mapController.camera.zoom);
    } catch (_) {
      // Ignore if the map isn't ready yet.
    }

    if (enteringNewTerritory) {
      unawaited(_vibrate(durationMs: 40));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('New path discovered'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _confirmStop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this walk?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('End'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _stopAndSave();
    }
  }

  Future<void> _stopAndSave() async {
    _trackingService.stop();
    _timer?.cancel();
    _stopStepCounting();
    await BackgroundTrackingService.stop();
    unawaited(_vibrate(durationMs: 80));

    final endTime = DateTime.now();
    final route = SavedRoute(
      points: List.of(_liveRoutePoints),
      startTime: (_walkStartTime ?? endTime).millisecondsSinceEpoch,
      endTime: endTime.millisecondsSinceEpoch,
      elapsedSeconds: _seconds,
      steps: _steps,
      newAreaKm: _newAreaMeters / 1000,
    );
    final discoveries = [
      for (final p in _sessionDiscoveryPoints)
        DiscoveryPoint(position: p, timestamp: endTime.millisecondsSinceEpoch),
    ];

    await DatabaseHelper.instance.saveRoute(route, discoveries);

    final distanceKm = _distanceMeters / 1000;
    final summary = WalkSummary(
      elapsedSeconds: _seconds,
      steps: _steps,
      newAreaKm: _newAreaMeters / 1000,
      distanceKm: distanceKm,
      routePoints: List.of(_liveRoutePoints),
      segmentIsNew: List.of(_liveSegmentIsNew),
    );

    double routeDistanceKm(SavedRoute r) =>
        r.steps * TrackingService.strideLengthMeters / 1000;
    final priorRoutes = _savedRoutes;
    final averageDistanceKm = priorRoutes.isEmpty
        ? null
        : priorRoutes.map(routeDistanceKm).reduce((a, b) => a + b) /
              priorRoutes.length;
    final totalWalks = priorRoutes.length + 1;
    final totalDistanceKm =
        priorRoutes.map(routeDistanceKm).fold(0.0, (a, b) => a + b) +
        distanceKm;

    setState(() {
      _isTracking = false;
      _liveRoutePoints.clear();
      _liveSegmentIsNew.clear();
      _sessionDiscoveryPoints.clear();
      _sessionIndex.clear();
      _pendingSessionNodes.clear();
      _heldJump = null;
      _wasInNewTerritory = false;
      _displayedIsNew = false;
      _pendingFlipStreak = 0;
      _seconds = 0;
      _steps = 0;
      _distanceMeters = 0;
      _newAreaMeters = 0;
      _currentPosition = null;
    });

    await _loadSavedData();
    _loadWeather();

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultsScreen(
          summary: summary,
          totalWalks: totalWalks,
          totalDistanceKm: totalDistanceKm,
          averageDistanceKm: averageDistanceKm,
          last7DaysKm: _computeLast7DaysKm(),
        ),
      ),
    );
  }

  /// Total distance per day for the last 7 days (oldest first, today last),
  /// derived from steps the same way [averageDistanceKm] is above.
  List<double> _computeLast7DaysKm() {
    final today = DateTime.now();
    return [
      for (var i = 6; i >= 0; i--)
        () {
          final day = DateTime(today.year, today.month, today.day - i);
          var total = 0.0;
          for (final r in _savedRoutes) {
            if (_isSameDate(_dateOnly(r.startTime), day)) {
              total += r.steps * TrackingService.strideLengthMeters / 1000;
            }
          }
          return total;
        }(),
    ];
  }

  void _showPermissionIssue(LocationAccessResult result) {
    // A GPS-off issue and a permission-denied issue are different problems
    // with different fixes, so they get different titles, wording and a
    // settings button that opens the *correct* settings page for each.
    final String title;
    final String message;
    final String actionLabel;
    final VoidCallback openSettings;

    switch (result) {
      case LocationAccessResult.serviceDisabled:
        title = 'Turn on location';
        message = 'Location is switched off on this device. Turn it on to track your walk.';
        actionLabel = 'Turn On Location';
        openSettings = Geolocator.openLocationSettings;
        break;
      case LocationAccessResult.deniedForever:
        title = 'Location access needed';
        message = 'Location access is permanently denied for Oway. Enable it for this app in Settings to track your walk.';
        actionLabel = 'Open App Settings';
        openSettings = Geolocator.openAppSettings;
        break;
      case LocationAccessResult.denied:
      case LocationAccessResult.granted:
        title = 'Location access needed';
        message = 'Oway needs location access to track your walk.';
        actionLabel = 'Open App Settings';
        openSettings = Geolocator.openAppSettings;
        break;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              openSettings();
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmExit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exit app?'),
        content: Text(
          _isTracking
              ? 'Do you want to exit the application? Your walk in progress will be lost.'
              : 'Do you want to exit the application?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      if (_isTracking) _abandonTracking();
      SystemNavigator.pop();
    }
  }

  Future<void> _openSettings() async {
    final dataCleared = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const SettingsScreen()));
    if (dataCleared == true) {
      setState(() => _historyFilterDate = null);
      await _loadSavedData();
    }
  }

  Future<void> _openWeatherDetails() async {
    final details = _weatherDetails;
    if (details == null) return;
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Weather details',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (context, animation, secondaryAnimation) =>
          const SizedBox.shrink(),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
        );
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
            alignment: Alignment.topRight,
            child: _WeatherDetailSheet(
              details: details,
              locationName: _locationName,
            ),
          ),
        );
      },
    );
  }

  Future<void> _openHistoryCalendar() async {
    final picked = await showDialog<Object>(
      context: context,
      barrierColor: Colors.black26,
      builder: (ctx) => _HistoryCalendarDialog(
        daysWithWalks: _daysWithWalks,
        selectedDate: _historyFilterDate,
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == _HistoryCalendarDialog.clearFilter) {
      setState(() => _historyFilterDate = null);
      return;
    }
    final day = picked as DateTime;
    setState(() => _historyFilterDate = day);
    final dayRoutes = _visibleRoutes;
    if (dayRoutes.isNotEmpty && dayRoutes.last.points.isNotEmpty) {
      try {
        _mapController.move(dayRoutes.last.points.last, 15);
      } catch (_) {
        // Map not ready yet; ignore.
      }
    }
  }

  // Right-side floating buttons sit above the bottom sheet; this is roughly
  // the sheet's rendered height (handle + legend + stats + button + padding).
  static const double _sheetClearance = 280;

  @override
  Widget build(BuildContext context) {
    final gpsOn = _isTracking;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _confirmExit();
      },
      child: Builder(
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final onScaffoldText = isDark ? Colors.white70 : Colors.black54;
          final onScaffoldIcon = isDark ? Colors.white : Colors.black87;
          return Scaffold(
            body: Column(
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: Icon(Icons.settings, color: onScaffoldIcon),
                          onPressed: _openSettings,
                        ),
                        Row(
                          children: [
                            if (_locationName != null) ...[
                              Icon(
                                Icons.location_on,
                                size: 14,
                                color: onScaffoldText,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                _locationName!,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: onScaffoldText,
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            if (_weatherDetails != null)
                              _WeatherChip(
                                weather: _weatherDetails!.current,
                                onTap: _openWeatherDetails,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(24),
                      topRight: Radius.circular(24),
                    ),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: _loading
                              ? Container(
                                  color: AppColors.mapPlaceholder,
                                  child: const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              : FlutterMap(
                                  mapController: _mapController,
                                  options: MapOptions(
                                    initialCenter:
                                        _currentPosition ??
                                        (_savedRoutes.isNotEmpty &&
                                                _savedRoutes
                                                    .last
                                                    .points
                                                    .isNotEmpty
                                            ? _savedRoutes.last.points.last
                                            : _fallbackCenter),
                                    initialZoom: 15,
                                  ),
                                  children: [
                                    TileLayer(
                                      urlTemplate: _mapStyle.urlTemplate,
                                      userAgentPackageName:
                                          'com.example.my_app',
                                      maxNativeZoom: _mapStyle.maxNativeZoom,
                                    ),
                                    if (_mapStyle.labelsUrlTemplate != null)
                                      TileLayer(
                                        urlTemplate:
                                            _mapStyle.labelsUrlTemplate!,
                                        userAgentPackageName:
                                            'com.example.my_app',
                                        maxNativeZoom: _mapStyle.maxNativeZoom,
                                      ),
                                    AnimatedBuilder(
                                      animation: _routeReveal,
                                      builder: (context, _) => PolylineLayer(
                                        polylines: [
                                          for (final r in _visibleRoutes)
                                            if (r.points.length > 1)
                                              Polyline(
                                                points: _revealed(
                                                  r.points,
                                                  _routeReveal.value,
                                                ),
                                                color: AppColors.savedRoute,
                                                strokeWidth: 4,
                                              ),
                                          for (
                                            var i = 0;
                                            i < _liveRoutePoints.length - 1;
                                            i++
                                          )
                                            Polyline(
                                              points: [
                                                _liveRoutePoints[i],
                                                _liveRoutePoints[i + 1],
                                              ],
                                              color:
                                                  (i <
                                                          _liveSegmentIsNew
                                                              .length &&
                                                      _liveSegmentIsNew[i])
                                                  ? AppColors.discoveryAmber
                                                  : AppColors.liveRoute,
                                              strokeWidth: 4,
                                            ),
                                        ],
                                      ),
                                    ),
                                    MarkerLayer(
                                      markers: [
                                        if (_currentPosition != null)
                                          Marker(
                                            point: _currentPosition!,
                                            width: 18,
                                            height: 18,
                                            child: Container(
                                              decoration: const BoxDecoration(
                                                color: AppColors.accentBlue,
                                                shape: BoxShape.circle,
                                                border: Border.fromBorderSide(
                                                  BorderSide(
                                                    color: Colors.white,
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                        ),
                        if (!_loading) ...[
                          Positioned(
                            left: 12,
                            top: 12,
                            child: Column(
                              children: [
                                _MapCircleButton(
                                  icon: Icons.add,
                                  onTap: () => _zoomBy(1),
                                ),
                                const SizedBox(height: 8),
                                _MapCircleButton(
                                  icon: Icons.remove,
                                  onTap: () => _zoomBy(-1),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            left: 6,
                            bottom: _sheetClearance + 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              color: Colors.white70,
                              child: Text(
                                _mapStyle.attribution,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.black54,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            bottom: _sheetClearance + 12,
                            child: _MapCircleButton(
                              icon: Icons.my_location,
                              onTap: _onLocateMePressed,
                            ),
                          ),
                          Positioned(
                            right: 12,
                            bottom: _sheetClearance + 60,
                            child: PopupMenuButton<_MapStyle>(
                              tooltip: 'Map style',
                              initialValue: _mapStyle,
                              onSelected: (style) =>
                                  setState(() => _mapStyle = style),
                              itemBuilder: (context) => [
                                for (final style in _MapStyle.values)
                                  PopupMenuItem(
                                    value: style,
                                    child: Row(
                                      children: [
                                        Icon(
                                          style.icon,
                                          size: 18,
                                          color: Colors.black87,
                                        ),
                                        const SizedBox(width: 10),
                                        Text(style.label),
                                        if (style == _mapStyle) ...[
                                          const Spacer(),
                                          const Icon(
                                            Icons.check,
                                            size: 16,
                                            color: AppColors.primaryGreen,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                              ],
                              child: _MapCircleButton(icon: _mapStyle.icon),
                            ),
                          ),
                        ],
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(24),
                                topRight: Radius.circular(24),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 16,
                                  offset: const Offset(0, -4),
                                ),
                              ],
                            ),
                            child: SafeArea(
                              top: false,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  10,
                                  20,
                                  20,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: AppColors.cardBorder,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        const _MapLegend(),
                                        _HistoryButton(
                                          isFiltered:
                                              _historyFilterDate != null,
                                          onTap: _openHistoryCalendar,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 18),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: StatColumn(
                                            icon: Icons.access_time,
                                            label: 'Time',
                                            value: _formattedTime,
                                          ),
                                        ),
                                        const StatDivider(),
                                        Expanded(
                                          child: StatColumn(
                                            icon: Icons.directions_walk,
                                            label: 'Steps',
                                            value: '$_steps',
                                          ),
                                        ),
                                        const StatDivider(),
                                        Expanded(
                                          child: StatColumn(
                                            icon: Icons.trending_up,
                                            label: 'Distance',
                                            value:
                                                '${(_distanceMeters / 1000).toStringAsFixed(2)} km',
                                          ),
                                        ),
                                        const StatDivider(),
                                        Expanded(
                                          child: StatColumn(
                                            icon: Icons.navigation_outlined,
                                            label: 'GPS',
                                            value: gpsOn ? 'ON' : 'OFF',
                                            valueColor: gpsOn
                                                ? AppColors.primaryGreen
                                                : Colors.black38,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 20),
                                    SizedBox(
                                      width: double.infinity,
                                      height: 52,
                                      child: ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _isTracking
                                              ? AppColors.dangerRed
                                              : AppColors.primaryGreen,
                                          foregroundColor: Colors.white,
                                          disabledBackgroundColor:
                                              AppColors.primaryGreen,
                                          disabledForegroundColor: Colors.white,
                                          elevation: 0,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              26,
                                            ),
                                          ),
                                        ),
                                        onPressed: _acquiringGps
                                            ? null
                                            : _onStartStopPressed,
                                        child: _acquiringGps
                                            ? const Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  SizedBox(
                                                    width: 18,
                                                    height: 18,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.white,
                                                        ),
                                                  ),
                                                  SizedBox(width: 12),
                                                  Text(
                                                    'Locating…',
                                                    style: TextStyle(
                                                      fontSize: 17,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      letterSpacing: 0.3,
                                                    ),
                                                  ),
                                                ],
                                              )
                                            : Text(
                                                _isTracking ? 'Stop' : 'Start',
                                                style: const TextStyle(
                                                  fontSize: 17,
                                                  fontWeight: FontWeight.w600,
                                                  letterSpacing: 0.3,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MapCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _MapCircleButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: AppColors.accentBlue),
        ),
      ),
    );
  }
}

class _HistoryButton extends StatelessWidget {
  final bool isFiltered;
  final VoidCallback onTap;

  const _HistoryButton({required this.isFiltered, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isFiltered
          ? AppColors.primaryGreen.withValues(alpha: 0.12)
          : AppColors.mapPlaceholder.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_month,
                size: 16,
                color: isFiltered ? AppColors.primaryGreen : Colors.black54,
              ),
              const SizedBox(width: 6),
              Text(
                'History',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isFiltered ? AppColors.primaryGreen : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryCalendarDialog extends StatefulWidget {
  final Set<DateTime> daysWithWalks;
  final DateTime? selectedDate;

  /// Sentinel returned by [Navigator.pop] when the user asks to clear the
  /// day filter instead of picking one.
  static const Object clearFilter = _ClearFilterMarker();

  const _HistoryCalendarDialog({
    required this.daysWithWalks,
    this.selectedDate,
  });

  @override
  State<_HistoryCalendarDialog> createState() => _HistoryCalendarDialogState();
}

class _ClearFilterMarker {
  const _ClearFilterMarker();
}

class _HistoryCalendarDialogState extends State<_HistoryCalendarDialog> {
  late DateTime _displayedMonth;

  static const _weekdayLabels = [
    'Sun',
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
  ];
  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  @override
  void initState() {
    super.initState();
    final base = widget.selectedDate ?? DateTime.now();
    _displayedMonth = DateTime(base.year, base.month);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _displayedMonth = DateTime(
        _displayedMonth.year,
        _displayedMonth.month + delta,
      );
    });
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final firstOfMonth = DateTime(
      _displayedMonth.year,
      _displayedMonth.month,
      1,
    );
    final daysInMonth = DateTime(
      _displayedMonth.year,
      _displayedMonth.month + 1,
      0,
    ).day;
    final leadingBlanks = firstOfMonth.weekday % 7;

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _shiftMonth(-1),
                    ),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${_monthNames[_displayedMonth.month - 1]} ${_displayedMonth.year}',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _shiftMonth(1),
                    ),
                  ],
                ),
                Row(
                  children: [
                    for (final label in _weekdayLabels)
                      Expanded(
                        child: Center(
                          child: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black45,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisExtent: 44,
                  ),
                  itemCount: leadingBlanks + daysInMonth,
                  itemBuilder: (context, index) {
                    if (index < leadingBlanks) return const SizedBox.shrink();
                    final day = index - leadingBlanks + 1;
                    final date = DateTime(
                      _displayedMonth.year,
                      _displayedMonth.month,
                      day,
                    );
                    final hasWalk = widget.daysWithWalks.any(
                      (d) => _isSameDate(d, date),
                    );
                    final isSelected =
                        widget.selectedDate != null &&
                        _isSameDate(widget.selectedDate!, date);
                    final isToday = _isSameDate(today, date);

                    return InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: hasWalk
                          ? () => Navigator.of(context).pop(date)
                          : null,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected ? AppColors.accentBlue : null,
                              border: isToday && !isSelected
                                  ? Border.all(
                                      color: AppColors.accentBlue,
                                      width: 1.4,
                                    )
                                  : null,
                            ),
                            child: Text(
                              '$day',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: isSelected
                                    ? Colors.white
                                    : hasWalk
                                    ? Colors.black87
                                    : Colors.black26,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: hasWalk
                                  ? AppColors.primaryGreen
                                  : Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context)
                          .pop(_HistoryCalendarDialog.clearFilter),
                  child: const Text('Show all days'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData weatherIconFor(int code) {
  if (code == 0) return Icons.wb_sunny;
  if (code <= 2) return Icons.wb_cloudy;
  if (code == 3) return Icons.cloud;
  if (code == 45 || code == 48) return Icons.blur_on;
  if (code >= 51 && code <= 67) return Icons.grain;
  if (code >= 80 && code <= 82) return Icons.grain;
  if (code >= 71 && code <= 86) return Icons.ac_unit;
  if (code >= 95) return Icons.bolt;
  return Icons.wb_cloudy;
}

class _WeatherChip extends StatelessWidget {
  final CurrentWeather weather;
  final VoidCallback onTap;

  const _WeatherChip({required this.weather, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.mapPlaceholder.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                weatherIconFor(weather.weatherCode),
                size: 16,
                color: Colors.black54,
              ),
              const SizedBox(width: 6),
              Text(
                '${weather.temperatureC.round()}°C',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeatherDetailSheet extends StatelessWidget {
  final WeatherDetails details;
  final String? locationName;

  const _WeatherDetailSheet({required this.details, this.locationName});

  String _hourLabel(DateTime time) {
    final now = DateTime.now();
    if (time.hour == now.hour && time.day == now.day) return 'Now';
    final h = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final suffix = time.hour < 12 ? 'AM' : 'PM';
    return '$h$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final current = details.current;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 90, left: 20, right: 20),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          elevation: 10,
          shadowColor: Colors.black38,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (locationName != null) ...[
                  Text(
                    locationName!,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    Icon(
                      weatherIconFor(current.weatherCode),
                      size: 44,
                      color: AppColors.neutralDark,
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${current.temperatureC.round()}°C',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                            height: 1.0,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          WeatherService.labelFor(current.weatherCode),
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      'Feels like\n${current.feelsLikeC.round()}°C',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black45,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                if (details.hourly.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Divider(height: 1, color: AppColors.cardBorder),
                  const SizedBox(height: 16),
                  const Text(
                    'HOURLY FORECAST',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: Colors.black45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 86,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: details.hourly.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 18),
                      itemBuilder: (context, i) {
                        final h = details.hourly[i];
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _hourLabel(h.time),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: i == 0
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: i == 0
                                    ? AppColors.primaryGreen
                                    : Colors.black54,
                              ),
                            ),
                            Icon(
                              weatherIconFor(h.weatherCode),
                              size: 20,
                              color: AppColors.neutralDark,
                            ),
                            Text(
                              '${h.temperatureC.round()}°',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapLegend extends StatelessWidget {
  const _MapLegend();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        _LegendItem(color: AppColors.liveRoute, label: 'Walked before'),
        SizedBox(width: 16),
        _LegendItem(color: AppColors.discoveryAmber, label: 'New'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
      ],
    );
  }
}
