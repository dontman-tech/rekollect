import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class MessagingService {
  const MessagingService(this._messaging);

  final FirebaseMessaging _messaging;

  Future<void> initializeForRole(String role, {required String uid}) async {
    await _messaging.requestPermission(alert: true, badge: true, sound: true);
    final token = await _messaging.getToken();
    if (token != null) {
      // Persist on the user document so fan-out can target devices directly.
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .update({'fcm_tokens': FieldValue.arrayUnion([token])});
      } on FirebaseException {
        // users doc may not exist yet on first login; topics still cover us.
      }
    }
    if (role == 'collector') {
      await _messaging.subscribeToTopic('collectors');
    } else {
      await _messaging.subscribeToTopic('generators');
    }
  }
}
