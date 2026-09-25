import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/pickup_request.dart';

class FirestoreService {
  FirestoreService(this._db);

  final FirebaseFirestore _db;

  /// Visible to screens that compose services (e.g. geofenced confirmation).
  FirebaseFirestore get db => _db;

  static const int maxOpenRequests = 3;

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
      tx.update(ref, {
        'status': 'claimed',
        'collector_id': collectorId,
        'claimed_at': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Only the collector who owns the claim may complete it.
  Future<void> completeRequest({
    required String requestId,
    required String collectorId,
  }) async {
    final ref = _db.collection('requests').doc(requestId);
    await _db.runTransaction((tx) async {
      final snapshot = await tx.get(ref);
      if (!snapshot.exists) {
        throw const RequestNotFoundException();
      }
      final data = snapshot.data()!;
      if (data['status'] == 'completed') return; // idempotent
      if (data['status'] != 'claimed' || data['collector_id'] != collectorId) {
        throw const NotClaimOwnerException();
      }
      tx.update(ref, {
        'status': 'completed',
        'completed_at': FieldValue.serverTimestamp(),
      });
    });
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

