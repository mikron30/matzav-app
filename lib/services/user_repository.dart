import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/status_models.dart';

class UserRepository {
  UserRepository._();
  static final instance = UserRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String defaultCountryCode = '972';

  String normalizeEmail(String value) => value.trim().toLowerCase();

  String normalizePhone(String value) {
    var digits = value.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.startsWith('00')) digits = '+${digits.substring(2)}';
    if (digits.startsWith('+')) return digits;
    digits = digits.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('0')) {
      return '+$defaultCountryCode${digits.substring(1)}';
    }
    return '+$digits';
  }

  String identityHash(String type, String normalizedValue) {
    final input = utf8.encode('$type:$normalizedValue');
    return sha256.convert(input).toString();
  }

  Future<void> ensureUserProfile(User user) async {
    final profileRef = _db.collection('profiles').doc(user.uid);
    final privateRef = _db.collection('private_users').doc(user.uid);

    final existing = await profileRef.get();
    final displayName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (user.email?.split('@').first ?? user.phoneNumber ?? 'חבר');

    final batch = _db.batch();
    batch.set(
      profileRef,
      {
        'uid': user.uid,
        'displayName': displayName,
        'photoUrl': user.photoURL,
        'activity': existing.data()?['activity'] ?? ActivityStatus.home.name,
        'availability': existing.data()?['availability'] ?? AvailabilityStatus.canTalk.name,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    batch.set(
      privateRef,
      {
        'email': user.email,
        'phone': user.phoneNumber,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    if (user.email != null && user.email!.trim().isNotEmpty) {
      final normalized = normalizeEmail(user.email!);
      final hash = identityHash('email', normalized);
      batch.set(_db.collection('public_ids').doc(hash), {
        'uid': user.uid,
        'kind': 'email',
        'ownerUid': user.uid,
      });
    }

    if (user.phoneNumber != null && user.phoneNumber!.trim().isNotEmpty) {
      final normalized = normalizePhone(user.phoneNumber!);
      final hash = identityHash('phone', normalized);
      batch.set(_db.collection('public_ids').doc(hash), {
        'uid': user.uid,
        'kind': 'phone',
        'ownerUid': user.uid,
      });
    }

    await batch.commit();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> profileStream(String uid) {
    return _db.collection('profiles').doc(uid).snapshots();
  }

  Future<void> updateStatus({
    required String uid,
    ActivityStatus? activity,
    AvailabilityStatus? availability,
  }) async {
    final data = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (activity != null) data['activity'] = activity.name;
    if (availability != null) data['availability'] = availability.name;
    await _db.collection('profiles').doc(uid).set(data, SetOptions(merge: true));
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> friendsStream(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('friends')
        .orderBy('contactName')
        .snapshots();
  }

  Future<String?> findUserUidByContact({String? phone, String? email}) async {
    final hashes = <String>[];
    if (phone != null && phone.trim().isNotEmpty) {
      hashes.add(identityHash('phone', normalizePhone(phone)));
    }
    if (email != null && email.trim().isNotEmpty) {
      hashes.add(identityHash('email', normalizeEmail(email)));
    }

    for (final hash in hashes) {
      final doc = await _db.collection('public_ids').doc(hash).get();
      if (doc.exists) {
        final uid = doc.data()?['uid'] as String?;
        if (uid != null && uid.isNotEmpty) return uid;
      }
    }
    return null;
  }

  Future<void> addFriendContact({
    required String ownerUid,
    required String contactName,
    String? phone,
    String? email,
  }) async {
    final friendUid = await findUserUidByContact(phone: phone, email: email);
    final keyMaterial = '${phone ?? ''}|${email ?? ''}|$contactName';
    final key = sha256.convert(utf8.encode(keyMaterial)).toString().substring(0, 24);

    await _db.collection('users').doc(ownerUid).collection('friends').doc(key).set({
      'contactName': contactName,
      'phone': phone,
      'email': email,
      'friendUid': friendUid,
      'state': friendUid == null ? 'pending' : 'installed',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> resolvePendingFriends(String ownerUid) async {
    final pending = await _db
        .collection('users')
        .doc(ownerUid)
        .collection('friends')
        .where('state', isEqualTo: 'pending')
        .get();

    for (final doc in pending.docs) {
      final data = doc.data();
      final friendUid = await findUserUidByContact(
        phone: data['phone'] as String?,
        email: data['email'] as String?,
      );
      if (friendUid != null && friendUid != ownerUid) {
        await doc.reference.update({
          'friendUid': friendUid,
          'state': 'installed',
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    }
  }

  Future<void> saveZone({
    required String uid,
    required String name,
    required double latitude,
    required double longitude,
    double radiusMeters = 150,
  }) {
    return _db.collection('private_users').doc(uid).set({
      'zones': {
        name: {
          'lat': latitude,
          'lng': longitude,
          'radius': radiusMeters,
        }
      },
    }, SetOptions(merge: true));
  }

  Future<Map<String, dynamic>> getZones(String uid) async {
    final doc = await _db.collection('private_users').doc(uid).get();
    final zones = doc.data()?['zones'];
    if (zones is Map<String, dynamic>) return zones;
    if (zones is Map) return Map<String, dynamic>.from(zones);
    return {};
  }
}
