import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/walk_models.dart';

class ResultsScreen extends StatelessWidget {
  final WalkSummary summary;

  const ResultsScreen({super.key, required this.summary});

  String get _formattedTime {
    final m = (summary.elapsedSeconds ~/ 60).toString();
    final s = (summary.elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  LatLng get _center {
    if (summary.routePoints.isEmpty) return const LatLng(0, 0);
    final lat = summary.routePoints.map((p) => p.latitude).reduce((a, b) => a + b) /
        summary.routePoints.length;
    final lng = summary.routePoints.map((p) => p.longitude).reduce((a, b) => a + b) /
        summary.routePoints.length;
    return LatLng(lat, lng);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Walk complete',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                flex: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: summary.routePoints.length < 2
                      ? Container(
                          color: const Color(0xFFE9E4D8),
                          child: const Center(
                            child: Icon(Icons.map_outlined, size: 48, color: Colors.black26),
                          ),
                        )
                      : FlutterMap(
                          options: MapOptions(
                            initialCenter: _center,
                            initialZoom: 15,
                            interactionOptions: const InteractionOptions(
                              flags: InteractiveFlag.none,
                            ),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.example.my_app',
                              maxNativeZoom: 17,
                            ),
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: summary.routePoints,
                                  color: Colors.green,
                                  strokeWidth: 4,
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                flex: 3,
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFFA9B5A0),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _StatRow(icon: Icons.access_time, label: 'Time', value: _formattedTime),
                      _StatRow(
                        icon: Icons.directions_walk,
                        label: 'Steps',
                        value: '${summary.steps}',
                      ),
                      _StatRow(
                        icon: Icons.explore_outlined,
                        label: 'New area explored',
                        value: '${summary.newAreaKm.toStringAsFixed(2)} km',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4F4F4F),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Done',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
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

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.black87),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(fontSize: 16, color: Colors.black87),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.black87),
        ),
      ],
    );
  }
}
