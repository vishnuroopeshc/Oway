import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/walk_models.dart';
import '../theme/app_colors.dart';
import '../widgets/stat_column.dart';

class ResultsScreen extends StatelessWidget {
  final WalkSummary summary;
  final int totalWalks;
  final double totalDistanceKm;
  final double? averageDistanceKm;

  const ResultsScreen({
    super.key,
    required this.summary,
    required this.totalWalks,
    required this.totalDistanceKm,
    this.averageDistanceKm,
  });

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
    final hasComparison = averageDistanceKm != null && averageDistanceKm! > 0;
    final maxCompareKm = hasComparison
        ? [summary.distanceKm, averageDistanceKm!].reduce((a, b) => a > b ? a : b)
        : summary.distanceKm;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Walk complete',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Nice work out there',
                style: TextStyle(fontSize: 14, color: Colors.black54),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  height: 220,
                  child: summary.routePoints.length < 2
                      ? Container(
                          color: AppColors.mapPlaceholder,
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
                                for (var i = 0; i < summary.routePoints.length - 1; i++)
                                  Polyline(
                                    points: [summary.routePoints[i], summary.routePoints[i + 1]],
                                    color: (i < summary.segmentIsNew.length && summary.segmentIsNew[i])
                                        ? AppColors.discoveryAmber
                                        : AppColors.liveRoute,
                                    strokeWidth: 4,
                                  ),
                              ],
                            ),
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: summary.routePoints.first,
                                  width: 16,
                                  height: 16,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(color: AppColors.liveRoute, width: 3),
                                    ),
                                  ),
                                ),
                                Marker(
                                  point: summary.routePoints.last,
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
                          ],
                        ),
                ),
              ),
              if (summary.routePoints.length >= 2) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    _LegendDot(color: AppColors.liveRoute, label: 'Walked before'),
                    SizedBox(width: 16),
                    _LegendDot(color: AppColors.discoveryAmber, label: 'New'),
                  ],
                ),
              ],
              if (summary.newAreaKm > 0) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.discoveryAmber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.explore, color: Color(0xFFB8860B), size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${summary.newAreaKm.toStringAsFixed(2)} km of new area discovered',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF8A6300),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              StatCard(
                child: Row(
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
                        value: '${summary.steps}',
                      ),
                    ),
                    const StatDivider(),
                    Expanded(
                      child: StatColumn(
                        icon: Icons.trending_up,
                        label: 'Distance',
                        value: '${summary.distanceKm.toStringAsFixed(2)} km',
                      ),
                    ),
                  ],
                ),
              ),
              if (hasComparison) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This walk vs. your average',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.black54,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _ComparisonBar(
                        label: 'This walk',
                        valueKm: summary.distanceKm,
                        maxKm: maxCompareKm,
                        color: AppColors.primaryGreen,
                      ),
                      const SizedBox(height: 10),
                      _ComparisonBar(
                        label: 'Your average',
                        valueKm: averageDistanceKm!,
                        maxKm: maxCompareKm,
                        color: AppColors.primaryGreen.withValues(alpha: 0.35),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                '$totalWalks walks · ${totalDistanceKm.toStringAsFixed(1)} km all time',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.black45),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.neutralDark,
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

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

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

class _ComparisonBar extends StatelessWidget {
  final String label;
  final double valueKm;
  final double maxKm;
  final Color color;

  const _ComparisonBar({
    required this.label,
    required this.valueKm,
    required this.maxKm,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = maxKm <= 0 ? 0.0 : (valueKm / maxKm).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            Text(
              '${valueKm.toStringAsFixed(2)} km',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.black87),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Stack(
          children: [
            Container(
              height: 10,
              decoration: BoxDecoration(
                color: AppColors.cardBorder,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            FractionallySizedBox(
              widthFactor: ratio,
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
