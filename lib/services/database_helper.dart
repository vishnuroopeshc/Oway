import 'package:latlong2/latlong.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/walk_models.dart';

class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  Database? _db;

  Future<Database> get _database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'trailwise.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE routes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time INTEGER NOT NULL,
            end_time INTEGER NOT NULL,
            elapsed_seconds INTEGER NOT NULL,
            steps INTEGER NOT NULL,
            new_area_km REAL NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE route_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            route_id INTEGER NOT NULL,
            seq INTEGER NOT NULL,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE discovery_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            route_id INTEGER NOT NULL,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  Future<int> saveRoute(
    SavedRoute route,
    List<DiscoveryPoint> discoveries,
  ) async {
    final db = await _database;
    return db.transaction<int>((txn) async {
      final routeId = await txn.insert('routes', {
        'start_time': route.startTime,
        'end_time': route.endTime,
        'elapsed_seconds': route.elapsedSeconds,
        'steps': route.steps,
        'new_area_km': route.newAreaKm,
      });

      final batch = txn.batch();
      for (var i = 0; i < route.points.length; i++) {
        final p = route.points[i];
        batch.insert('route_points', {
          'route_id': routeId,
          'seq': i,
          'lat': p.latitude,
          'lng': p.longitude,
          'timestamp': route.startTime,
        });
      }
      for (final d in discoveries) {
        batch.insert('discovery_points', {
          'route_id': routeId,
          'lat': d.position.latitude,
          'lng': d.position.longitude,
          'timestamp': d.timestamp,
        });
      }
      await batch.commit(noResult: true);
      return routeId;
    });
  }

  Future<List<SavedRoute>> loadAllRoutes() async {
    final db = await _database;
    final routeRows = await db.query('routes', orderBy: 'start_time ASC');
    final routes = <SavedRoute>[];
    for (final row in routeRows) {
      final routeId = row['id'] as int;
      final pointRows = await db.query(
        'route_points',
        where: 'route_id = ?',
        whereArgs: [routeId],
        orderBy: 'seq ASC',
      );
      routes.add(
        SavedRoute(
          id: routeId,
          points: pointRows
              .map((p) => LatLng(p['lat'] as double, p['lng'] as double))
              .toList(),
          startTime: row['start_time'] as int,
          endTime: row['end_time'] as int,
          elapsedSeconds: row['elapsed_seconds'] as int,
          steps: row['steps'] as int,
          newAreaKm: row['new_area_km'] as double,
        ),
      );
    }
    return routes;
  }

  Future<void> clearAllData() async {
    final db = await _database;
    await db.transaction((txn) async {
      await txn.delete('route_points');
      await txn.delete('discovery_points');
      await txn.delete('routes');
    });
  }

  Future<List<DiscoveryPoint>> loadAllDiscoveryPoints() async {
    final db = await _database;
    final rows = await db.query('discovery_points');
    return rows
        .map(
          (r) => DiscoveryPoint(
            id: r['id'] as int,
            routeId: r['route_id'] as int,
            position: LatLng(r['lat'] as double, r['lng'] as double),
            timestamp: r['timestamp'] as int,
          ),
        )
        .toList();
  }
}
