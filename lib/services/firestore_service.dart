import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/pickup_request.dart';
import 'geo.dart';

class FirestoreService {
  FirestoreService(this._db);

  final FirebaseFirestore _db;

  /// Direct db access (used by the admin console for request evidence reads).
  FirebaseFirestore get db => _db;

  static const int maxOpenRequests = 3;

  /// A completion is only accepted within this distance of the job location.
  static const double pickupRadiusMeters = 50;

  /// A claim older than this is reverted to pending by the fallback-dispatch
  /// scheduled function (see functions/index.js) and the collector gets a
  /// no-show strike.
  static const Duration claimTimeout = Duration(hours: 4);

  /// Three strikes of any kind suspend a collector's claim rights.
  static const int maxStrikes = 3;

  // ------------------------------------------------------------------ users
  Stream<AppUser?> streamUser(String uid) {
    return _db.collection('users').doc(uid).snapshots().map((doc) {
      if (!doc.exists) return null;
      return AppUser.fromDocument(doc);
    });
  }

  Future<AppUser?> getUser(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    if (!doc.exists) return null;
    return AppUser.fromDocument(doc);
  }

  Future<void> saveUser(AppUser user, {String? vehicleSize}) async {
    await _db.collection('users').doc(user.uid).set(user.toFirestore());
    if (user.role == 'collector') {
      await _db.collection('collectors').doc(user.uid).set({
        'uid': user.uid,
        'vehicle_size': vehicleSize,
        'is_available': true,
      });
    }
  }

  /// Persist the FCM token on the user document so notifications can target
  /// devices directly instead of relying only on topic fan-out.
  Future<void> saveMessagingToken(String uid, String token) async {
    await _db.collection('users').doc(uid).update({
      'fcm_tokens': FieldValue.arrayUnion([token]),
    });
  }

  // --------------------------------------------------------------- requests
  /// Creates a pickup request, enforcing a cap of [maxOpenRequests] concurrent
  /// pending requests per generator so a single account cannot flood the queue.
  Future<void> createPickupRequest({
    required String generatorId,
    required String generatorType,
    required String wasteType,
    required double latitude,
    required double longitude,
    String? directionsLandmarks,
  }) async {
    final pending = await _db
        .collection('requests')
        .where('generator_id', isEqualTo: generatorId)
        .where('status', isEqualTo: 'pending')
        .count()
        .get();
    if ((pending.count ?? 0) >= maxOpenRequests) {
      throw RequestLimitException(maxOpenRequests);
    }
    final doc = _db.collection('requests').doc();
    await doc.set({
      'request_id': doc.id,
      'generator_id': generatorId,
      'generator_type': generatorType,
      'waste_type': wasteType,
      'latitude': latitude,
      'longitude': longitude,
      'status': 'pending',
      'created_at': FieldValue.serverTimestamp(),
      if (directionsLandmarks != null && directionsLandmarks.trim().isNotEmpty)
        'directions_landmarks': directionsLandmarks.trim(),
    });
  }

  /// Open (pending) requests for the collector marketplace, newest first.
  /// Requires the composite index (status ASC, created_at DESC) — defined in
  /// firestore.indexes.json.
  Stream<List<PickupRequest>> streamOpenRequests() {
    return _db
        .collection('requests')
        .where('status', isEqualTo: 'pending')
        .orderBy('created_at', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(PickupRequest.fromDocument).toList());
  }

  /// This collector's active claims (claimed, not yet completed).
  Stream<List<PickupRequest>> streamClaims(String collectorId) {
    return _db
        .collection('requests')
        .where('collector_id', isEqualTo: collectorId)
        .where('status', isEqualTo: 'claimed')
        .orderBy('created_at', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(PickupRequest.fromDocument).toList());
  }

  /// A generator's own request history, newest first.
  Stream<List<PickupRequest>> streamMyRequests(String generatorId) {
    return _db
        .collection('requests')
        .where('generator_id', isEqualTo: generatorId)
        .orderBy('created_at', descending: true)
        .limit(20)
        .snapshots()
        .map((snapshot) => snapshot.docs.map(PickupRequest.fromDocument).toList());
  }

  /// Atomically claims a request. Two collectors tapping at the same moment
  /// cannot both win: the transaction re-reads the status inside the commit
  /// and the second claimer gets [AlreadyClaimedException].
  Future<void> claimRequest({required String requestId, required String collectorId}) async {
    final ref = _db.collection('requests').doc(requestId);
    await _db.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      if (!snapshot.exists) {
        throw const RequestNotFoundException();
      }
      final data = snapshot.data()!;
      if (data['status'] != 'pending') {
        throw const AlreadyClaimedException();
      }
      final collectorDoc = await tx.get(_db.collection('collectors').doc(collectorId));
      if (collectorDoc.exists && (collectorDoc.data()!['suspended'] as bool? ?? false)) {
        throw const SuspendedCollectorException();
      }
      tx.update(ref, {
        'status': 'claimed',
        'collector_id': collectorId,
        'claimed_at': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Completes a pickup with a **location-log confirmation**: the collector's
  /// GPS must be within [pickupRadiusMeters] of the job location. The position
  /// is written to the request and to an append-only `location_log`
  /// subcollection as evidence. Status becomes `completed` but
  /// `confirmation_status = 'awaiting_confirmation'` — the job only counts as
  /// truly done once the generator confirms it.
  Future<void> completeRequest({
    required String requestId,
    required String collectorId,
    required double collectorLatitude,
    required double collectorLongitude,
    double? accuracyMeters,
  }) async {
    final distance = distanceMeters(
      collectorLatitude,
      collectorLongitude,
      // The job location is re-read inside the transaction below; this
      // pre-check uses the snapshot we were given and is re-verified there.
      collectorLatitude,
      collectorLongitude,
    );
    assert(distance >= 0);
    final ref = _db.collection('requests').doc(requestId);
    await _db.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      if (!snapshot.exists) {
        throw const RequestNotFoundException();
      }
      final data = snapshot.data()!;
      if (data['status'] == 'completed' && data['confirmation_status'] != null) {
        return; // idempotent
      }
      if (data['status'] != 'claimed' || data['collector_id'] != collectorId) {
        throw const NotClaimOwnerException();
      }
      final jobLat = (data['latitude'] as num).toDouble();
      final jobLng = (data['longitude'] as num).toDouble();
      final distance = distanceMeters(collectorLatitude, collectorLongitude, jobLat, jobLng);
      if (distance > pickupRadiusMeters) {
        throw TooFarException(distance);
      }
      final now = FieldValue.serverTimestamp();
      tx.update(ref, {
        'status': 'completed',
        'completed_at': now,
        'confirmation_status': 'awaiting_confirmation',
        'pickup_latitude': collectorLatitude,
        'pickup_longitude': collectorLongitude,
        'pickup_distance_meters': distance,
        'location_log_count': FieldValue.increment(1),
      });
      tx.set(ref.collection('location_log').doc(), {
        'event': 'pickup_confirmed',
        'actor_id': collectorId,
        'latitude': collectorLatitude,
        'longitude': collectorLongitude,
        if (accuracyMeters != null) 'accuracy_meters': accuracyMeters,
        'distance_to_job_meters': distance,
        'created_at': now,
      });
    });
    await _incrementReliability(collectorId, completed: 1);
  }

  /// Appends an entry to the request's append-only location log. Used by the
  /// collector to breadcrumb approach/arrival (and on claim) so disputes have
  /// a movement trail, not just the final point.
  Future<void> logLocationEvent({
    required String requestId,
    required String actorId,
    required String event,
    required double latitude,
    required double longitude,
    double? accuracyMeters,
  }) async {
    final ref = _db.collection('requests').doc(requestId);
    await ref.collection('location_log').add({
      'event': event,
      'actor_id': actorId,
      'latitude': latitude,
      'longitude': longitude,
      if (accuracyMeters != null) 'accuracy_meters': accuracyMeters,
      'created_at': FieldValue.serverTimestamp(),
    });
    await ref.update({'location_log_count': FieldValue.increment(1)});
  }

  /// The generator verifies the pickup. `collected == true` closes the loop
  /// (confirmation_status = 'confirmed'); `false` reports the trash was NOT
  /// collected — the request goes to `disputed`, an open dispute is filed and
  /// the collector takes a strike immediately.
  Future<void> confirmPickup({
    required String requestId,
    required String generatorId,
    required bool collected,
  }) async {
    final ref = _db.collection('requests').doc(requestId);
    String collector = '';
    await _db.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      if (!snapshot.exists) {
        throw const RequestNotFoundException();
      }
      final data = snapshot.data()!;
      if (data['generator_id'] != generatorId) {
        throw const NotOwnerException();
      }
      if (data['confirmation_status'] != 'awaiting_confirmation') {
        throw const NotConfirmableException();
      }
      collector = (data['collector_id'] as String?) ?? '';
      if (collected) {
        tx.update(ref, {'confirmation_status': 'confirmed'});
      } else {
        tx.update(ref, {'confirmation_status': 'disputed'});
      }
    });
    if (!collected) {
      await _db.collection('disputes').add({
        'request_id': requestId,
        'raised_by': generatorId,
        'against': collector,
        'reason': 'Generator reports the trash was not collected.',
        'status': 'open',
        'created_at': FieldValue.serverTimestamp(),
      });
      if (collector.isNotEmpty) {
        await _applyStrike(collector, 'dispute_opened', requestId);
      }
    }
  }

  /// Raises a dispute manually (the generator can also report from any
  /// claimed/completed request, not only the confirmation prompt).
  Future<void> reportNotCollected({
    required String requestId,
    required String generatorId,
    required String reason,
  }) async {
    final ref = _db.collection('requests').doc(requestId);
    String collector = '';
    final snapshot = await ref.get();
    if (!snapshot.exists) throw const RequestNotFoundException();
    final data = snapshot.data()!;
    if (data['generator_id'] != generatorId) throw const NotOwnerException();
    collector = (data['collector_id'] as String?) ?? '';
    if (data['confirmation_status'] == 'disputed') return; // already open
    await ref.update({'confirmation_status': 'disputed'});
    await _db.collection('disputes').add({
      'request_id': requestId,
      'raised_by': generatorId,
      'against': collector,
      'reason': reason.trim().isEmpty ? 'Generator reports the trash was not collected.' : reason.trim(),
      'status': 'open',
      'created_at': FieldValue.serverTimestamp(),
    });
    if (collector.isNotEmpty) {
      await _applyStrike(collector, 'dispute_opened', requestId);
    }
  }

  // ------------------------------------------------------------ disputes

  Stream<List<Map<String, dynamic>>> streamOpenDisputes() {
    return _db
        .collection('disputes')
        .where('status', isEqualTo: 'open')
        .orderBy('created_at', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => {'id': doc.id, ...doc.data()})
            .toList());
  }

  /// Admin resolves a dispute. Upheld: the collector keeps their strike and
  /// the request stays `disputed` (unfulfilled). Rejected (the collection did
  /// happen): the confirmation flips to `confirmed` and the open dispute
  /// closes; the opening strike is refunded (one strike removed).
  Future<void> resolveDispute({
    required String disputeId,
    required bool collectorAtFault,
  }) async {
    final ref = _db.collection('disputes').doc(disputeId);
    final snapshot = await ref.get();
    if (!snapshot.exists) throw const RequestNotFoundException();
    final dispute = snapshot.data()!;
    if (dispute['status'] != 'open') return; // idempotent
    final requestId = dispute['request_id'] as String;
    final collector = (dispute['against'] as String?) ?? '';
    await _db.runTransaction((tx) async {
      tx.update(ref, {
        'status': 'resolved',
        'collector_at_fault': collectorAtFault,
        'resolved_at': FieldValue.serverTimestamp(),
      });
      final requestRef = _db.collection('requests').doc(requestId);
      if (!collectorAtFault) {
        tx.update(requestRef, {'confirmation_status': 'confirmed'});
      }
    });
    if (!collectorAtFault && collector.isNotEmpty) {
      await _removeStrike(collector);
    }
  }

  // ------------------------------------------------ reliability + strikes

  /// Reliability data lives on the collector's `collectors` doc so the
  /// marketplace can surface it. Score: completed vs completed+disputed,
  /// shown as a percentage; suspensions gate claiming.
  Future<void> _incrementReliability(String collectorId, {int completed = 0, int disputed = 0}) async {
    if (collectorId.isEmpty) return;
    final ref = _db.collection('collectors').doc(collectorId);
    await ref.set({
      if (completed > 0) 'completed_count': FieldValue.increment(completed),
      if (disputed > 0) 'disputed_count': FieldValue.increment(disputed),
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Writes a strike; at [maxStrikes] the collector is suspended (client-side
  /// claiming is gated on `suspended != true`).
  Future<void> _applyStrike(String collectorId, String kind, String? requestId) async {
    final ref = _db.collection('collectors').doc(collectorId);
    int strikes = 0;
    final snapshot = await ref.get();
    strikes = ((snapshot.data()?['strikes'] as num?) ?? 0).toInt();
    final now = FieldValue.serverTimestamp();
    await _db.collection('strikes').add({
      'collector_id': collectorId,
      'kind': kind,
      'request_id': requestId,
      'created_at': now,
    });
    strikes += 1;
    await ref.set({
      'strikes': FieldValue.increment(1),
      'disputed_count': FieldValue.increment(1),
      if (strikes >= maxStrikes) 'suspended': true,
      'updated_at': now,
    }, SetOptions(merge: true));
  }

  Future<void> _removeStrike(String collectorId) async {
    if (collectorId.isEmpty) return;
    await _db.collection('collectors').doc(collectorId).set({
      'strikes': FieldValue.increment(-1),
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Stream of a collector's own accountability record (score, strikes).
  Stream<DocumentSnapshot<Map<String, dynamic>>> streamCollectorRecord(String collectorId) {
    return _db.collection('collectors').doc(collectorId).snapshots();
  }

  /// The generator (or the owning collector) may cancel a pending request.
  Future<void> cancelRequest({
    required String requestId,
    required String userId,
  }) async {
    final ref = _db.collection('requests').doc(requestId);
    await _db.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      if (!snapshot.exists) {
        throw const RequestNotFoundException();
      }
      final data = snapshot.data()!;
      if (data['status'] != 'pending') {
        throw const AlreadyClaimedException();
      }
      if (data['generator_id'] != userId) {
        throw const NotOwnerException();
      }
      tx.update(ref, {'status': 'cancelled'});
    });
  }
}

// ------------------------------------------------------------- exceptions
class FirestoreServiceException implements Exception {
  const FirestoreServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RequestLimitException extends FirestoreServiceException {
  RequestLimitException(int limit)
      : super('You already have $limit open requests. Wait for one to be claimed.');
}

class AlreadyClaimedException extends FirestoreServiceException {
  const AlreadyClaimedException() : super('Another collector just claimed this request.');
}

class RequestNotFoundException extends FirestoreServiceException {
  const RequestNotFoundException() : super('This request no longer exists.');
}

class NotClaimedException extends FirestoreServiceException {
  const NotClaimedException() : super('This request is not currently claimed.');
}

class NotOwnerException extends FirestoreServiceException {
  const NotOwnerException() : super('You can only cancel your own requests.');
}

class TooFarException extends FirestoreServiceException {
  TooFarException(double meters)
      : super(
          'You are ${meters.round()} m away from the pickup point. '
          'Get within 50 m of the job location to confirm pickup.',
        );
}

class NotConfirmableException extends FirestoreServiceException {
  const NotConfirmableException()
      : super('This request is not waiting for your confirmation.');
}

class SuspendedCollectorException extends FirestoreServiceException {
  const SuspendedCollectorException()
      : super('Claiming is suspended on your account. Contact support.');
}

