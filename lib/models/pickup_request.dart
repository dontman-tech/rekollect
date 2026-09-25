import 'package:cloud_firestore/cloud_firestore.dart';

class PickupRequest {
  const PickupRequest({
    required this.requestId,
    required this.generatorId,
    required this.generatorType,
    required this.wasteType,
    required this.latitude,
    required this.longitude,
    required this.status,
    required this.createdAt,
    this.collectorId,
    this.directionsLandmarks,
  });

  final String requestId;
  final String generatorId;
  final String generatorType;
  final String wasteType;
  final double latitude;
  final double longitude;
  final String status;
  final Timestamp? createdAt;
  final String? collectorId;
  final String? directionsLandmarks;

  bool get isPending => status == 'pending';
  bool get isClaimed => status == 'claimed';
  bool get isCompleted => status == 'completed';
  bool get isPickedUp => status == 'picked_up';
  bool get isDisputed => status == 'disputed';
  bool get isCancelled => status == 'cancelled';

  factory PickupRequest.fromDocument(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    return PickupRequest(
      requestId: data['request_id'] as String? ?? doc.id,
      generatorId: data['generator_id'] as String? ?? '',
      generatorType: data['generator_type'] as String? ?? 'individual',
      wasteType: data['waste_type'] as String? ?? 'Organic',
      latitude: (data['latitude'] as num?)?.toDouble() ?? 4.1593,
      longitude: (data['longitude'] as num?)?.toDouble() ?? 9.2435,
      status: data['status'] as String? ?? 'pending',
      createdAt: data['created_at'] as Timestamp?,
      collectorId: data['collector_id'] as String?,
      directionsLandmarks: data['directions_landmarks'] as String?,
      relistedCount: (data['relisted_count'] as num?)?.toInt() ?? 0,
    );
  }
}
