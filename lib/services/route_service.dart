import '../models/pickup_request.dart';
import 'geo.dart';

/// Route density mode — an *optional* collector tool that turns scattered
/// one-tap claiming into a short efficient loop: it clusters the nearby open
/// requests around the collector's current position and orders them so a
/// collector can sweep a whole street instead of cherry-picking single easy
/// jobs (and leaving the hard ones stranded).
class PlannedRoute {
  const PlannedRoute({required this.stops, required this.skipped});

  /// Nearby pending requests, ordered by walking distance from the collector.
  final List<PlannedStop> stops;
  final List<PickupRequest> skipped;
}

class PlannedStop {
  const PlannedStop({required this.request, required this.distanceMeters});

  final PickupRequest request;
  final double distanceMeters;
}

class RoutePlanner {
  const RoutePlanner();

  static const double defaultRadiusKm = 1.5;
  static const int maxStops = 5;

  PlannedRoute plan({
    required List<PickupRequest> openRequests,
    required double collectorLatitude,
    required double collectorLongitude,
    double radiusKm = defaultRadiusKm,
  }) {
    final stops = <PlannedStop>[];
    final skipped = <PickupRequest>[];
    for (final request in openRequests) {
      final distance = distanceMeters(
        collectorLatitude,
        collectorLongitude,
        request.latitude,
        request.longitude,
      );
      if (distance <= radiusKm * 1000) {
        stops.add(PlannedStop(request: request, distanceMeters: distance));
      } else {
        skipped.add(request);
      }
    }
    stops.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
    final trimmed = stops.length > maxStops ? stops.sublist(0, maxStops) : stops;
    return PlannedRoute(stops: trimmed, skipped: skipped);
  }
}
