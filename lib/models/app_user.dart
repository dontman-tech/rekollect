import 'package:cloud_firestore/cloud_firestore.dart';

class AppUser {
  const AppUser({
    required this.uid,
    required this.name,
    required this.phoneNumber,
    required this.role,
    required this.generalLocation,
    this.generatorType,
  });

  final String uid;
  final String name;
  final String phoneNumber;
  final String role;
  final String generalLocation;
  final String? generatorType;

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
    );
  }
}
