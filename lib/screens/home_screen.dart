import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/walk_models.dart';
import '../services/database_helper.dart';
import '../services/tracking_service.dart';
import '../theme/app_colors.dart';
import '../widgets/stat_column.dart';
import 'results_screen.dart';

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
        _MapStyle.satellite =>
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        _MapStyle.minimal =>
          'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}',
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

  /// Grid cells (see [TrackingService.cellKeyFor]) covered by every walk
  /// saved before this session started.
  Set<String> _knownCells = {};

  bool _isTracking = false;
  Timer? _timer;
  DateTime? _walkStartTime;
  int _seconds = 0;
  int _steps = 0;
  double _distanceMeters = 0;
  double _newAreaMeters = 0;
  LatLng? _currentPosition;
  final List<LatLng> _liveRoutePoints = [];
  final List<bool> _liveSegmentIsNew = [];
  final List<LatLng> _sessionDiscoveryPoints = [];

  /// Cells revealed for the first time during the walk in progress.
  final Set<String> _revealedThisWalk = {};
  bool _wasInNewTerritory = false;

  Set<String> _computeKnownCells(List<SavedRoute> routes) {
    final cells = <String>{};
    for (final route in routes) {
      for (var i = 0; i < route.points.length; i++) {
        if (i == 0) {
          cells.add(TrackingService.cellKeyFor(route.points[i]));
          continue;
        }
        for (final sample in TrackingService.sampleAlong(route.points[i - 1], route.points[i])) {
          cells.add(TrackingService.cellKeyFor(sample));
        }
      }
    }
    return cells;
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trackingService.stop();
    _timer?.cancel();
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
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      if (_isTracking) {
        _abandonTracking();
      }
    }
  }

  Future<void> _loadSavedData() async {
    final routes = await DatabaseHelper.instance.loadAllRoutes();
    if (!mounted) return;
    setState(() {
      _savedRoutes = routes;
      _knownCells = _computeKnownCells(routes);
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
    setState(() {
      _isTracking = false;
      _liveRoutePoints.clear();
      _liveSegmentIsNew.clear();
      _sessionDiscoveryPoints.clear();
      _revealedThisWalk.clear();
      _wasInNewTerritory = false;
      _seconds = 0;
      _steps = 0;
      _distanceMeters = 0;
      _newAreaMeters = 0;
    });
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

    setState(() {
      _isTracking = true;
      _liveRoutePoints.clear();
      _liveSegmentIsNew.clear();
      _sessionDiscoveryPoints.clear();
      _revealedThisWalk.clear();
      _wasInNewTerritory = false;
      _seconds = 0;
      _steps = 0;
      _distanceMeters = 0;
      _newAreaMeters = 0;
      _walkStartTime = DateTime.now();
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
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
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final point = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() => _currentPosition = point);
      _mapController.move(point, _mapController.camera.zoom);
    } catch (_) {
      // Ignore transient location errors; the user can try again.
    }
  }

  void _onPosition(Position position) {
    final point = LatLng(position.latitude, position.longitude);
    var segmentDistance = 0.0;
    var segmentIsNew = false;

    if (_liveRoutePoints.isNotEmpty) {
      final prev = _liveRoutePoints.last;
      segmentDistance = Geolocator.distanceBetween(
        prev.latitude,
        prev.longitude,
        point.latitude,
        point.longitude,
      );

      // Walk the cells this segment actually crosses (not just its
      // endpoint) so a fast GPS jump can't skip over new territory.
      for (final sample in TrackingService.sampleAlong(prev, point)) {
        final key = TrackingService.cellKeyFor(sample);
        if (!_knownCells.contains(key) && _revealedThisWalk.add(key)) {
          segmentIsNew = true;
        }
      }
      if (segmentIsNew) {
        _newAreaMeters += segmentDistance;
      }
    } else {
      final key = TrackingService.cellKeyFor(point);
      if (!_knownCells.contains(key)) {
        _revealedThisWalk.add(key);
      }
    }

    final enteringNewTerritory = segmentIsNew && !_wasInNewTerritory;
    _wasInNewTerritory = segmentIsNew;

    setState(() {
      _distanceMeters += segmentDistance;
      _steps = (_distanceMeters / TrackingService.strideLengthMeters).round();
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
      HapticFeedback.mediumImpact();
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
        : priorRoutes.map(routeDistanceKm).reduce((a, b) => a + b) / priorRoutes.length;
    final totalWalks = priorRoutes.length + 1;
    final totalDistanceKm =
        priorRoutes.map(routeDistanceKm).fold(0.0, (a, b) => a + b) + distanceKm;

    setState(() {
      _isTracking = false;
      _liveRoutePoints.clear();
      _liveSegmentIsNew.clear();
      _sessionDiscoveryPoints.clear();
      _revealedThisWalk.clear();
      _wasInNewTerritory = false;
      _seconds = 0;
      _steps = 0;
      _distanceMeters = 0;
      _newAreaMeters = 0;
      _currentPosition = null;
    });

    await _loadSavedData();

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ResultsScreen(
          summary: summary,
          totalWalks: totalWalks,
          totalDistanceKm: totalDistanceKm,
          averageDistanceKm: averageDistanceKm,
        ),
      ),
    );
  }

  void _showPermissionIssue(LocationAccessResult result) {
    final String message;
    switch (result) {
      case LocationAccessResult.serviceDisabled:
        message =
            'Location services are turned off on this device. Please enable them to track your walk.';
        break;
      case LocationAccessResult.deniedForever:
        message =
            'Location access is permanently denied for Trailwise. Please enable it in Settings to track your walk.';
        break;
      case LocationAccessResult.denied:
      case LocationAccessResult.granted:
        message = 'Trailwise needs location access to track your walk.';
        break;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Location access needed'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Geolocator.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gpsOn = _isTracking;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(Icons.settings, color: Colors.black87),
                  onPressed: () {},
                ),
              ),
              Expanded(
                flex: 5,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _loading
                      ? Container(
                          width: double.infinity,
                          color: AppColors.mapPlaceholder,
                          child: const Center(child: CircularProgressIndicator()),
                        )
                      : Stack(
                          children: [
                            FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: _currentPosition ??
                                (_savedRoutes.isNotEmpty && _savedRoutes.last.points.isNotEmpty
                                    ? _savedRoutes.last.points.last
                                    : _fallbackCenter),
                            initialZoom: 15,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: _mapStyle.urlTemplate,
                              userAgentPackageName: 'com.example.my_app',
                              maxNativeZoom: _mapStyle.maxNativeZoom,
                            ),
                            if (_mapStyle.labelsUrlTemplate != null)
                              TileLayer(
                                urlTemplate: _mapStyle.labelsUrlTemplate!,
                                userAgentPackageName: 'com.example.my_app',
                                maxNativeZoom: _mapStyle.maxNativeZoom,
                              ),
                            AnimatedBuilder(
                              animation: _routeReveal,
                              builder: (context, _) => PolylineLayer(
                                polylines: [
                                  for (final r in _savedRoutes)
                                    if (r.points.length > 1)
                                      Polyline(
                                        points: _revealed(r.points, _routeReveal.value),
                                        color: AppColors.savedRoute,
                                        strokeWidth: 4,
                                      ),
                                  for (var i = 0; i < _liveRoutePoints.length - 1; i++)
                                    Polyline(
                                      points: [_liveRoutePoints[i], _liveRoutePoints[i + 1]],
                                      color: (i < _liveSegmentIsNew.length && _liveSegmentIsNew[i])
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
                                          BorderSide(color: Colors.white, width: 2),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            Positioned(
                              left: 6,
                              bottom: 4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                color: Colors.white70,
                                child: Text(
                                  _mapStyle.attribution,
                                  style: const TextStyle(fontSize: 9, color: Colors.black54),
                                ),
                              ),
                            ),
                          ],
                            ),
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
                              right: 12,
                              bottom: 12,
                              child: _MapCircleButton(
                                icon: Icons.my_location,
                                onTap: _onLocateMePressed,
                              ),
                            ),
                            Positioned(
                              right: 12,
                              bottom: 60,
                              child: PopupMenuButton<_MapStyle>(
                                tooltip: 'Map style',
                                initialValue: _mapStyle,
                                onSelected: (style) => setState(() => _mapStyle = style),
                                itemBuilder: (context) => [
                                  for (final style in _MapStyle.values)
                                    PopupMenuItem(
                                      value: style,
                                      child: Row(
                                        children: [
                                          Icon(style.icon, size: 18, color: Colors.black87),
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
                        ),
                ),
              ),
              const SizedBox(height: 8),
              const _MapLegend(),
              const SizedBox(height: 8),
              Expanded(
                flex: 4,
                child: StatCard(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
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
                              icon: Icons.navigation_outlined,
                              label: 'GPS',
                              value: gpsOn ? 'ON' : 'OFF',
                              valueColor: gpsOn ? AppColors.primaryGreen : Colors.black38,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                _isTracking ? AppColors.dangerRed : AppColors.primaryGreen,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(26),
                            ),
                          ),
                          onPressed: _onStartStopPressed,
                          child: Text(
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
            ],
          ),
        ),
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
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
      ],
    );
  }
}
