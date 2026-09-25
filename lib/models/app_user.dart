import 'package:cloud_firestore/cloud_firestore.dart';

import 'pickup_request.dart';

class AppUser {
  const AppUser({
    required this.uid,
    required this.name,
    required this.phoneNumber,
    required this.role,
    required this.generalLocation,
    this.generatorType,
    this.wasteTypes = const [],
    this.vehicleType,
    this.zoneRadiusKm = 3,
    this.zoneLatitude,
    this.zoneLongitude,
  });

  final String uid;
  final String name;
  final String phoneNumber;
  final String role;
  final String generalLocation;
  final String? generatorType;

  /// Collector specialization: the waste types this collector handles. Jobs
  /// outside this set never reach their marketplace list.
  final List<String> wasteTypes;

  /// Collector vehicle — determines the max weight they can claim.
  final String? vehicleType;

  /// Coverage zone radius (km) around the zone center; outside is hidden.
  final double zoneRadiusKm;

  final double? zoneLatitude;

  final double? zoneLongitude;

  double get zoneCenterLat => zoneLatitude ?? 4.1593;

  double get zoneCenterLng => zoneLongitude ?? 9.2435;

  int get capacityKg =>
      kVehicleCapacities[vehicleType ?? 'motorbike'] ?? kVehicleCapacities['motorbike']!;

  bool handlesWaste(String type) => wasteTypes.isEmpty || wasteTypes.contains(type);

  bool get isGenerator => role == 'generator';
  bool get isCollector => role == 'collector';
  bool get isAdmin => role == 'admin';

  Map<String, Object?> toFirestore() {
    return {
      'uid': uid,
      'name': name,
      'phone_number': phoneNumber,
      'role': role,
      'generator_type': generatorType,
      'general_location': generalLocation,
      if (isCollector) ...[
        'waste_types': wasteTypes,
        'vehicle_type': vehicleType,
        'zone_radius_km': zoneRadiusKm,
        'zone_latitude': zoneLatitude,
        'zone_longitude': zoneLongitude,
      ],
    };
  }

  factory AppUser.fromDocument(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    return AppUser(
      uid: data['uid'] as String? ?? doc.id,
      name: data['name'] as String? ?? '',
      phoneNumber: data['phone_number'] as String? ?? '',
      role: data['role'] as String? ?? 'generator',
      generatorType: data['generator_type'] as String?,
      generalLocation: data['general_location'] as String? ?? '',
      wasteTypes: ((data['waste_types'] as List<dynamic>?) ?? const <dynamic>[])
          .map((value) => value as String)
          .toList(),
      vehicleType: data['vehicle_type'] as String?,
      zoneRadiusKm: (data['zone_radius_km'] as num?)?.toDouble() ?? 3,
      zoneLatitude: (data['zone_latitude'] as num?)?.toDouble(),
      zoneLongitude: (data['zone_longitude'] as num?)?.toDouble(),
    );
  }
}
