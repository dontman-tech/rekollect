import 'package:cloud_firestore/cloud_firestore.dart';

/// Waste categories a request or a collector can be tagged with. Collectors
/// only see jobs whose waste type is in their handled set — hazardous waste
/// in particular only routes to collectors who explicitly opted in.
const kAllWasteTypes = ['Organic', 'Plastic', 'Electronic', 'Bulky', 'Hazardous'];

/// Vehicle types and how much weight (kg) each can carry per job.
const kVehicleCapacities = <String, int>{
  'bicycle': 20,
  'motorbike': 50,
  'tricycle': 150,
  'pickup': 500,
  'truck': 1000,
};

const kVehicleTypes = kVehicleCapacities.keys.toList();

/// Rough quantity bands a generator can pick without knowing exact weight.
const kQuantityBands = <String, int>{
  'one-bag': 15,
  'few-bags': 40,
  'several-bags': 100,
  'bulk': 400,
};

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
    this.confirmationStatus,
    this.pickupLatitude,
    this.pickupLongitude,
    this.claimedAt,
    this.locationLogCount = 0,
    this.scheduledAt,
    this.recurrence = 'once',
    this.quantityBand,
    this.quantityKg,
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

  /// Two-sided pickup confirmation lifecycle:
  /// null (legacy/none) -> 'awaiting_confirmation' (collector completed at the
  /// job location) -> 'confirmed' (generator agreed) or 'disputed' (generator
  /// reported the trash was NOT collected; goes to the admin dispute queue).
  final String? confirmationStatus;

  /// The collector's GPS position logged at completion (the location-log
  /// confirmation). Null for legacy completed requests.
  final double? pickupLatitude;
  final double? pickupLongitude;
  final Timestamp? claimedAt;

  /// Denormalized count of location-log entries, shown as evidence in the
  /// dispute workflow without reading the subcollection.
  final int locationLogCount;

  /// Scheduled pickup: when the generator wants this collected. Null = ASAP.
  final Timestamp? scheduledAt;

  /// 'once' or 'weekly' — a weekly request auto-respawns after confirmation.
  final String recurrence;

  /// Generator-declared size band (key of kQuantityBands), shown to collectors
  /// and checked against vehicle capacity at claim time.
  final String? quantityBand;

  /// Optional exact weight, if the generator knows it.
  final int? quantityKg;

  bool get isRecurring => recurrence == 'weekly';

  /// The estimated weight a collector must be able to carry for this job.
  int get estimatedKg =>
      quantityKg ?? kQuantityBands[quantityBand ?? 'one-bag'] ?? kQuantityBands['one-bag']!;

  bool get isScheduled => scheduledAt != null;

  bool get isPending => status == 'pending';
  bool get isClaimed => status == 'claimed';
  bool get isCompleted => status == 'completed';
  bool get isAwaitingConfirmation => confirmationStatus == 'awaiting_confirmation';
  bool get isDisputed => confirmationStatus == 'disputed';
  bool get isConfirmed => confirmationStatus == 'confirmed';

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
      confirmationStatus: data['confirmation_status'] as String?,
      pickupLatitude: (data['pickup_latitude'] as num?)?.toDouble(),
      pickupLongitude: (data['pickup_longitude'] as num?)?.toDouble(),
      claimedAt: data['claimed_at'] as Timestamp?,
      locationLogCount: (data['location_log_count'] as num?)?.toInt() ?? 0,
      scheduledAt: data['scheduled_at'] as Timestamp?,
      recurrence: data['recurrence'] as String? ?? 'once',
      quantityBand: data['quantity_band'] as String?,
      quantityKg: (data['quantity_kg'] as num?)?.toInt(),
    );
  }
}
