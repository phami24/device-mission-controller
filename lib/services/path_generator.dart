import 'dart:math' as math;

class PathGenerator {
  // Convert lat/lon to meters (Web Mercator projection)
  Map<String, double> latLonToMeters(double lat, double lon) {
    const r = 6378137.0;
    final x = (lon * math.pi) / 180.0 * r;
    final y = math.log(math.tan(math.pi / 4.0 + (lat * math.pi) / 360.0)) * r;
    return {'x': x, 'y': y};
  }

  // Convert meters to lat/lon
  Map<String, int> metersToLatLon(double x, double y, double alt) {
    const r = 6378137.0;
    final lon = (x / r) * (180.0 / math.pi);
    final lat = (2.0 * math.atan(math.exp(y / r)) - math.pi / 2.0) * (180.0 / math.pi);
    return {
      'lat': (lat * 1e7).round(),
      'lon': (lon * 1e7).round(),
      'alt': alt.round(),
    };
  }

  // Check if point is inside polygon
  bool pointInPolygon(Map<String, double> p, List<Map<String, double>> poly) {
    bool inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i]['x']!, yi = poly[i]['y']!;
      final xj = poly[j]['x']!, yj = poly[j]['y']!;
      final intersect = ((yi > p['y']!) != (yj > p['y']!)) &&
          (p['x']! < (xj - xi) * (p['y']! - yi) / (yj - yi + 0.0) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  // Clip line to polygon
  List<Map<String, double>> clipLineToPolygon(
    Map<String, double> p1,
    Map<String, double> p2,
    List<Map<String, double>> poly,
  ) {
    const steps = 40;
    final insidePoints = <Map<String, double>>[];
    for (int i = 0; i <= steps; i++) {
      final t = i / steps;
      final x = p1['x']! + t * (p2['x']! - p1['x']!);
      final y = p1['y']! + t * (p2['y']! - p1['y']!);
      final pt = {'x': x, 'y': y};
      if (pointInPolygon(pt, poly)) {
        insidePoints.add(pt);
      } else {
        if (insidePoints.isNotEmpty) break;
      }
    }
    if (insidePoints.length < 2) return [];
    return [insidePoints.first, insidePoints.last];
  }

  // Rotate point around origin
  Map<String, double> rotatePoint(Map<String, double> p, double angleRad) {
    final cosA = math.cos(angleRad);
    final sinA = math.sin(angleRad);
    return {
      'x': p['x']! * cosA - p['y']! * sinA,
      'y': p['x']! * sinA + p['y']! * cosA,
    };
  }

  // Generate optimized path (similar to JavaScript version)
  List<Map<String, int>> generateOptimizedPath(
    List<Map<String, int>> polygonE7,
    Map<String, int> homeE7,
    double altitude,
    double fov,
    double headingDeg,
  ) {
    // Convert navigation bearing (0°=North, 90°=East, clockwise)
    // to math angle (0°=East, counter-clockwise) internally
    final headingRad = (90 - headingDeg) * math.pi / 180.0;
    final polyMeters = polygonE7.map((p) => latLonToMeters(p['lat']! / 1e7, p['lon']! / 1e7)).toList();
    final homeMeters = latLonToMeters(homeE7['lat']! / 1e7, homeE7['lon']! / 1e7);

    // Rotate polygon relative to home
    final rotatedPoly = polyMeters.map((p) {
      final rel = {'x': p['x']! - homeMeters['x']!, 'y': p['y']! - homeMeters['y']!};
      return rotatePoint(rel, -headingRad);
    }).toList();

    // Find bounding box
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final p in rotatedPoly) {
      if (p['x']! < minX) minX = p['x']!;
      if (p['x']! > maxX) maxX = p['x']!;
      if (p['y']! < minY) minY = p['y']!;
      if (p['y']! > maxY) maxY = p['y']!;
    }

    // Calculate step size based on altitude and FOV
    final footprint = 2 * altitude * math.tan((fov / 2.0) * math.pi / 180.0);
    final step = footprint * 0.8;

    // Generate scan lines
    final lines = <List<Map<String, double>>>[];
    for (double y = minY; y <= maxY; y += step) {
      final p1 = {'x': minX, 'y': y};
      final p2 = {'x': maxX, 'y': y};
      final clipped = clipLineToPolygon(p1, p2, rotatedPoly);
      if (clipped.isNotEmpty) lines.add(clipped);
    }

    // Connect lines (nearest neighbor approach)
    final visited = <int>{};
    final path = <Map<String, double>>[];
    var current = {'x': 0.0, 'y': 0.0};
    while (visited.length < lines.length) {
      int bestIdx = -1;
      double bestDist = double.infinity;
      bool reverse = false;
      for (int i = 0; i < lines.length; i++) {
        if (visited.contains(i)) continue;
        final d1 = math.sqrt(
          math.pow(current['x']! - lines[i][0]['x']!, 2) +
              math.pow(current['y']! - lines[i][0]['y']!, 2),
        );
        final d2 = math.sqrt(
          math.pow(current['x']! - lines[i][1]['x']!, 2) +
              math.pow(current['y']! - lines[i][1]['y']!, 2),
        );
        if (d1 < bestDist) {
          bestDist = d1;
          bestIdx = i;
          reverse = false;
        }
        if (d2 < bestDist) {
          bestDist = d2;
          bestIdx = i;
          reverse = true;
        }
      }
      if (bestIdx >= 0) {
        visited.add(bestIdx);
        if (!reverse) {
          path.add(lines[bestIdx][0]);
          path.add(lines[bestIdx][1]);
          current = lines[bestIdx][1];
        } else {
          path.add(lines[bestIdx][1]);
          path.add(lines[bestIdx][0]);
          current = lines[bestIdx][0];
        }
      }
    }

    // Convert back to lat/lon and rotate back
    final waypoints = <Map<String, int>>[];
    for (final pt in path) {
      final rotatedBack = rotatePoint(pt, headingRad);
      final absX = rotatedBack['x']! + homeMeters['x']!;
      final absY = rotatedBack['y']! + homeMeters['y']!;
      waypoints.add(metersToLatLon(absX, absY, altitude));
    }
    return waypoints;
  }
}

