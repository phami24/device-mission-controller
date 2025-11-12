import 'package:latlong2/latlong.dart';

class UploadService {
  void uploadTriangle(List<LatLng> points, double bearingDeg) {
    if (points.length != 3) {
      // ignore invalid
      return;
    }
    // For now, just print like the web version
    // In production, replace with API call
    // ignore: avoid_print
    print({
      'points': points
          .map((p) => {
                'lat': p.latitude,
                'lng': p.longitude,
              })
          .toList(),
      'bearing': bearingDeg,
    });
  }
}
