import 'package:geolocator/geolocator.dart';

/// Thin wrapper around geolocator so screens don't depend on the plugin's
/// types directly and permission flows are handled once, consistently.
class LocationService {
  const LocationService();

  /// Current device position, requesting permission and enabling services
  /// where needed. Throws a user-readable message on failure.
  Future<Position> getCurrentPosition() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw 'Location permission denied — it is required to confirm pickups.';
    }
    if (permission == LocationPermission.deniedForever) {
      throw 'Location permission is permanently denied. Enable it in system settings to confirm pickups.';
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw 'Device location is off. Turn on GPS to confirm pickups.';
    }
    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 15),
    );
  }
}
