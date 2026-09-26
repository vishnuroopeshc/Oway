import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/walk_models.dart';
import '../services/database_helper.dart';
import '../services/tracking_service.dart';
import 'results_screen.dart';

enum _MapStyle { terrain, streets, satellite }

extension on _MapStyle {
  String get label => switch (this) {
        _MapStyle.terrain => 'Terrain',
        _MapStyle.streets => 'Streets',
        _MapStyle.satellite => 'Satellite',
      };

  IconData get icon => switch (this) {
        _MapStyle.terrain => Icons.terrain,
        _MapStyle.streets => Icons.map_outlined,
        _MapStyle.satellite => Icons.satellite_alt,
      };

  String get urlTemplate => switch (this) {
        _MapStyle.terrain => 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
        _MapStyle.streets => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        _MapStyle.satellite =>
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      };

  int get maxNativeZoom => this == _MapStyle.terrain ? 17 : 19;

  String get attribution => switch (this) {
        _MapStyle.terrain => '© OpenTopoMap (CC-BY-SA)',
        _MapStyle.streets => '© OpenStreetMap contributors',
        _MapStyle.satellite => '© Esri, Maxar, Earthstar Geographics',
      };
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const LatLng _fallbackCenter = LatLng(37.7749, -122.4194);

  final MapController _mapController = MapController();
  final TrackingService _trackingService = TrackingService();

  _MapStyle _mapStyle = _MapStyle.terrain;

  bool _loading = true;
  List<SavedRoute> _savedRoutes = [];
  List<DiscoveryPoint> _savedDiscoveryPoints = [];

  bool _isTracking = false;
  Timer? _timer;
  DateTime? _walkStartTime;
  int _seconds = 0;
  int _steps = 0;
  double _distanceMeters = 0;
  double _newAreaMeters = 0;
  LatLng? _currentPosition;
  final List<LatLng> _liveRoutePoints = [];
  final List<LatLng> _sessionDiscoveryPoints = [];

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
    super.dispose();
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
    final discoveries = await DatabaseHelper.instance.loadAllDiscoveryPoints();
    if (!mounted) return;
    setState(() {
      _savedRoutes = routes;
      _savedDiscoveryPoints = discoveries;
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
  }

  void _abandonTracking() {
    _trackingService.stop();
    _timer?.cancel();
    setState(() {
      _isTracking = false;
      _liveRoutePoints.clear();
      _sessionDiscoveryPoints.clear();
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
      _sessionDiscoveryPoints.clear();
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

    if (_liveRoutePoints.isNotEmpty) {
      final prev = _liveRoutePoints.last;
      segmentDistance = Geolocator.distanceBetween(
        prev.latitude,
        prev.longitude,
        point.latitude,
        point.longitude,
      );

      final knownPool = [for (final r in _savedRoutes) ...r.points];
      final minDistToKnown = knownPool.isEmpty
          ? double.infinity
          : TrackingService.minDistanceTo(point, knownPool);
      if (minDistToKnown > TrackingService.newAreaThresholdMeters) {
        _newAreaMeters += segmentDistance;
      }
    }

    final referencePool = [
      for (final r in _savedRoutes) ...r.points,
      ..._sessionDiscoveryPoints,
    ];
    final minDistOverall = referencePool.isEmpty
        ? double.infinity
        : TrackingService.minDistanceTo(point, referencePool);
    final justDiscoveredNewArea = minDistOverall > TrackingService.newAreaThresholdMeters;

    setState(() {
      _distanceMeters += segmentDistance;
      _steps = (_distanceMeters / TrackingService.strideLengthMeters).round();
      _currentPosition = point;
      _liveRoutePoints.add(point);
      if (justDiscoveredNewArea) {
        _sessionDiscoveryPoints.add(point);
      }
    });

    try {
      _mapController.move(point, _mapController.camera.zoom);
    } catch (_) {
      // Ignore if the map isn't ready yet.
    }

    if (justDiscoveredNewArea) {
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

    final summary = WalkSummary(
      elapsedSeconds: _seconds,
      steps: _steps,
      newAreaKm: _newAreaMeters / 1000,
      routePoints: List.of(_liveRoutePoints),
    );

    setState(() {
      _isTracking = false;
      _liveRoutePoints.clear();
      _sessionDiscoveryPoints.clear();
      _seconds = 0;
      _steps = 0;
      _distanceMeters = 0;
      _newAreaMeters = 0;
      _currentPosition = null;
    });

    await _loadSavedData();

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ResultsScreen(summary: summary)),
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
                          color: const Color(0xFFE9E4D8),
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
                            PolylineLayer(
                              polylines: [
                                for (final r in _savedRoutes)
                                  if (r.points.length > 1)
                                    Polyline(points: r.points, color: Colors.blue, strokeWidth: 4),
                                if (_liveRoutePoints.length > 1)
                                  Polyline(
                                    points: _liveRoutePoints,
                                    color: Colors.green,
                                    strokeWidth: 4,
                                  ),
                              ],
                            ),
                            MarkerLayer(
                              markers: [
                                for (final d in _savedDiscoveryPoints)
                                  Marker(
                                    point: d.position,
                                    width: 14,
                                    height: 14,
                                    child: const _DiscoveryDot(),
                                  ),
                                for (final p in _sessionDiscoveryPoints)
                                  Marker(
                                    point: p,
                                    width: 14,
                                    height: 14,
                                    child: const _DiscoveryDot(),
                                  ),
                                if (_currentPosition != null)
                                  Marker(
                                    point: _currentPosition!,
                                    width: 18,
                                    height: 18,
                                    child: Container(
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF3B7DDD),
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
                                              color: Color(0xFF2E7D32),
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
              const SizedBox(height: 16),
              Expanded(
                flex: 4,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFFE7E4DC)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _StatColumn(
                              icon: Icons.access_time,
                              label: 'Time',
                              value: _formattedTime,
                            ),
                          ),
                          const _StatDivider(),
                          Expanded(
                            child: _StatColumn(
                              icon: Icons.directions_walk,
                              label: 'Steps',
                              value: '$_steps',
                            ),
                          ),
                          const _StatDivider(),
                          Expanded(
                            child: _StatColumn(
                              icon: Icons.navigation_outlined,
                              label: 'GPS',
                              value: gpsOn ? 'ON' : 'OFF',
                              valueColor: gpsOn ? const Color(0xFF2E7D32) : Colors.black38,
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
                            backgroundColor: _isTracking
                                ? const Color(0xFFD64545)
                                : const Color(0xFF2E7D32),
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
          child: Icon(icon, size: 20, color: const Color(0xFF3B7DDD)),
        ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatColumn({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: Colors.black45),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: valueColor ?? Colors.black87,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Colors.black45,
          ),
        ),
      ],
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 40,
      color: const Color(0xFFE7E4DC),
    );
  }
}

class _DiscoveryDot extends StatelessWidget {
  const _DiscoveryDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFFFC107),
        shape: BoxShape.circle,
        border: Border.fromBorderSide(BorderSide(color: Colors.white, width: 2)),
      ),
    );
  }
}
