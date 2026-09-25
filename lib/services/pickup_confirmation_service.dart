import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/pickup_request.dart';

/// Pickup confirmation with a 50m location gate: a collector can only mark a
/// job collected while physically near the tagged location, and the generator
/// must confirm (or report non-collection) before the job counts as done.
class PickupConfirmationService {
  PickupConfirmationService(this._db);

  final FirebaseFirestore _db;

  /// Collector must be within [gateMeters] of the request's tagged location.
  static const double gateMeters = 50.0;

  /// A claimed-but-unconfirmed job auto-returns to the pool after this long.
  static const Duration claimTimeout = Duration(hours: 48);

  /// The generator has this long to confirm/report after collector pickup.
  static const Duration confirmWindow = Duration(hours: 24);

  /// Strikes at which a collector is suspended from claiming.
  static const int strikesToSuspend = 3;

  // ------------------------------------------------------------ geofence
  /// Haversine distance in meters between two coordinates.
  static double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;

  /// True when the device fix is inside the 50m gate around the job.
  static bool withinGate({
    required PickupRequest request,
    required double latitude,
    required double longitude,
  }) {
    return distanceMeters(request.latitude, request.longitude, latitude, longitude) <= gateMeters;
  }

  // ------------------------------------------------- collector marks pickup
  /// Collector records pickup at the tagged location. Rejected when the fix
  /// is outside the 50m gate — no remote completion.
  Future<void> markPickedUp({
    required PickupRequest request,
    required String collectorId,
    required double latitude,
    required double longitude,
  }) async {
    final dist = distanceMeters(request.latitude, request.longitude, latitude, longitude);
    if (dist > gateMeters) {
      throw OutsideGateException(dist.round());
    }
    final ref = _db.collection('requests').doc(request.requestId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw const RequestNotFoundException();
      final data = snap.data()!;
      if (data['status'] != 'claimed') throw const NotClaimedException();
      if (data['collector_id'] != collectorId) throw const NotClaimOwnerException();
      tx.update(ref, {
        'status': 'picked_up',
        'pickup_confirmed_by': 'collector',
        'pickup_location': {
          'latitude': latitude,
          'longitude': longitude,
          // Distance from the tagged point, so the admin panel can audit
          // gate behavior even for in-gate completions.
          'distance_m': dist.round(),
        },
        'pickup_at': FieldValue.serverTimestamp(),
      });
    });
  }

  // ------------------------------------------------ generator confirmation
  /// Generator confirms the trash was actually collected. This is the step
  /// that closes the job — collector marking pickup alone does not.
  Future<void> confirmCollected({
    required PickupRequest request,
    required String generatorId,
  }) async {
    final ref = _db.collection('requests').doc(request.requestId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw const RequestNotFoundException();
      final data = snap.data()!;
      if (data['status'] != 'picked_up') throw const NotPickedUpException();
      if (data['generator_id'] != generatorId) throw const NotOwnerException();
      tx.update(ref, {
        'status': 'completed',
        'confirmed_by': 'generator',
        'confirmed_at': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Generator reports the trash was NOT collected. The job is returned to
  /// the pending pool, the claiming collector earns a strike, and the report
  /// is logged for the admin dispute queue.
  Future<void> reportNotCollected({
    required PickupRequest request,
    required String generatorId,
    String? reason,
  }) async {
    final ref = _db.collection('requests').doc(request.requestId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw const RequestNotFoundException();
      final data = snap.data()!;
      if (data['status'] != 'picked_up') throw const NotPickedUpException();
      if (data['generator_id'] != generatorId) throw const NotOwnerException();
      final collectorId = data['collector_id'] as String?;
      tx.update(ref, {
        'status': 'disputed',
        'dispute': {
          'reason': reason ?? 'not_collected',
          'reported_by': generatorId,
          'reported_at': FieldValue.serverTimestamp(),
          'dispute_state': 'open',
        },
      });
      if (collectorId != null) {
        tx.set(_db.collection('strikes').doc(), {
          'collector_id': collectorId,
          'request_id': request.requestId,
          'kind': 'reported_not_collected',
          'reason': reason ?? 'not_collected',
          'created_at': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  // --------------------------------------------------- fallback dispatch
  /// Releases a stale claim back to the pending pool (called by a scheduled
  /// sweep or on read). Optionally pings the collectors topic.
  Future<bool> releaseIfExpired(PickupRequest request) async {
    final claimedAt = request.createdAt;
    if (!request.isClaimed || claimedAt == null) return false;
    final age = DateTime.now().difference(claimedAt.toDate());
    if (age < claimTimeout) return false;
    await _db.collection('requests').doc(request.requestId).update({
      'status': 'pending',
      'collector_id': FieldValue.delete(),
      'claimed_at': FieldValue.delete(),
      'relisted_count': FieldValue.increment(1),
    });
    return true;
  }

  // ------------------------------------------------------------- strikes
  Stream<int> strikeCount(String collectorId) {
    return _db
        .collection('strikes')
        .where('collector_id', isEqualTo: collectorId)
        .snapshots()
        .map((s) => s.docs.length);
  }

  Future<bool> isSuspended(String collectorId) async {
    final strikes = await _db
        .collection('strikes')
        .where('collector_id', isEqualTo: collectorId)
        .count()
        .get();
    return (strikes.count ?? 0) >= strikesToSuspend;
  }

  // --------------------------------------------------- reliability score
  /// Reliability = completed ÷ (completed + disputed + stale-released), as a
  /// 0–100 int. A brand-new collector starts at 100 (null history shown as
  /// "new"). Disputes hurt immediately; confirmed completions restore it.
  Future<ReliabilityScore> reliability(String collectorId) async {
    final agg = await Future.wait([
      _db.collection('requests').where('collector_id', isEqualTo: collectorId).where('status', isEqualTo: 'completed').count().get(),
      _db.collection('requests').where('collector_id', isEqualTo: collectorId).where('status', isEqualTo: 'disputed').count().get(),
      _db.collection('strikes').where('collector_id', isEqualTo: collectorId).count().get(),
    ]);
    final completed = agg[0].count ?? 0;
    final disputed = agg[1].count ?? 0;
    final strikes = agg[2].count ?? 0;
    final total = completed + disputed;
    if (total == 0) {
      return ReliabilityScore(completed: 0, disputed: 0, strikes: strikes, percent: null);
    }
    // disputed counts double: a dispute is worse than a plain miss.
    final weight = completed - disputed;
    final percent = ((weight / total) * 100).clamp(0, 100).round();
    return ReliabilityScore(completed: completed, disputed: disputed, strikes: strikes, percent: percent);
  }

  // --------------------------------------------------- route density mode
  /// Groups open requests by proximity and returns batches of [maxBatch]
  /// within [clusterMeters] of the seed job, nearest-first. Collectors can
  /// take a whole cluster in one trip (optional mode — they can always claim
  /// single jobs).
  Future<List<List<PickupRequest>>> clustersFor({
    required List<PickupRequest> openRequests,
    required double latitude,
    required double longitude,
    double clusterMeters = 800,
    int maxBatch = 5,
  }) async {
    final sorted = [...openRequests]
      ..sort((a, b) {
        final da = distanceMeters(latitude, longitude, a.latitude, a.longitude);
        final db = distanceMeters(latitude, longitude, b.latitude, b.longitude);
        return da.compareTo(db);
      });
    final remaining = List<PickupRequest>.from(sorted);
    final batches = <List<PickupRequest>>[];
    while (remaining.isNotEmpty && batches.length < 3) {
      final seed = remaining.removeAt(0);
      final batch = [seed];
      remaining.retainWhere((r) {
        if (batch.length >= maxBatch) return true;
        final inRange =
            distanceMeters(seed.latitude, seed.longitude, r.latitude, r.longitude) <= clusterMeters;
        if (inRange && batch.length < maxBatch) {
          batch.add(r);
          return false;
        }
        return true;
      });
      batches.add(batch);
    }
    return batches;
  }

  // ------------------------------------------------------ admin disputes
  /// Admin queue: open disputes, oldest first.
  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> openDisputes() {
    return _db
        .collection('requests')
        .where('status', isEqualTo: 'disputed')
        .orderBy('created_at', descending: false)
        .snapshots()
        .map((s) => s.docs);
  }

  /// Admin verdict:
  ///   uphold  — collector at fault: job re-opens to the pool, strike stands.
  ///   dismiss — generator mistaken: job completes, strike removed.
  Future<void> resolveDispute({
    required String requestId,
    required bool uphold,
    String? adminNote,
  }) async {
    final ref = _db.collection('requests').doc(requestId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (!snap.exists) throw const RequestNotFoundException();
      final data = snap.data()!;
      if (data['status'] != 'disputed') throw const NotDisputeedException();
      final dispute = (data['dispute'] as Map<String, dynamic>?) ?? {};
      final collectorId = data['collector_id'] as String?;
      if (uphold) {
        tx.update(ref, {
          'status': 'pending',
          'collector_id': FieldValue.delete(),
          'claimed_at': FieldValue.delete(),
          'pickup_confirmed_by': FieldValue.delete(),
          'dispute.dispute_state': 'resolved_upheld',
          'dispute.admin_note': adminNote,
          'relisted_count': FieldValue.increment(1),
        });
      } else {
        tx.update(ref, {
          'status': 'completed',
          'confirmed_by': 'admin',
          'confirmed_at': FieldValue.serverTimestamp(),
          'dispute.dispute_state': 'resolved_dismissed',
          'dispute.admin_note': adminNote,
        });
        if (collectorId != null) {
          // remove the newest matching strike for this collector/request
          final strikes = await _db
              .collection('strikes')
              .where('collector_id', isEqualTo: collectorId)
              .where('request_id', isEqualTo: requestId)
              .limit(1)
              .get();
          for (final d in strikes.docs) {
            tx.delete(d.reference);
          }
        }
      }
    });
  }
}

// --------------------------------------------------------------- score
class ReliabilityScore {
  const ReliabilityScore({
    required this.completed,
    required this.disputed,
    required this.strikes,
    this.percent,
  });

  final int completed;
  final int disputed;
  final int strikes;

  /// Null = no history yet (shown as "new").
  final int? percent;

  bool get suspended => strikes >= PickupConfirmationService.strikesToSuspend;
}

// ---------------------------------------------------------- exceptions
class ConfirmationException implements Exception {
  const ConfirmationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OutsideGateException extends ConfirmationException {
  OutsideGateException(int meters)
      : super('You are ${meters}m from the pickup point — go within '
          '${PickupConfirmationService.gateMeters.round()}m to confirm pickup.');
}

class NotPickedUpException extends ConfirmationException {
  const NotPickedUpException() : super('This job has not been marked picked up yet.');
}

class NotClaimOwnerException extends ConfirmationException {
  const NotClaimOwnerException() : super('This job belongs to another collector.');
}

class NotDisputeedException extends ConfirmationException {
  const NotDisputeedException() : super('This job is not in dispute.');
}

class RequestNotFoundException extends ConfirmationException {
  const RequestNotFoundException() : super('This request no longer exists.');
}

class NotClaimedException extends ConfirmationException {
  const NotClaimedException() : super('This job is not currently claimed.');
}

class NotOwnerException extends ConfirmationException {
  const NotOwnerException() : super('Not your request.');
}
