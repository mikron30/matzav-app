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

  bool isValidPhone(String value) {
    final normalized = normalizePhone(value);
    return RegExp(r'^\+[0-9]{8,15}$').hasMatch(normalized);
  }

  String identityHash(String type, String normalizedValue) {
    final input = utf8.encode('$type:$normalizedValue');
    return sha256.convert(input).toString();
  }

  Future<void> ensureUserProfile(User user) async {
    final profileRef = _db.collection('profiles').doc(user.uid);
    final privateRef = _db.collection('private_users').doc(user.uid);

    final existing = await profileRef.get();
    final existingPrivate = await privateRef.get();
    final displayName = (user.displayName?.trim().isNotEmpty ?? false)
        ? user.displayName!.trim()
        : (user.email?.split('@').first ?? user.phoneNumber ?? 'חבר');

    final authPhone = user.phoneNumber?.trim();
    final storedPhone = existingPrivate.data()?['phone'] as String?;
    final effectivePhone = authPhone != null && authPhone.isNotEmpty
        ? normalizePhone(authPhone)
        : storedPhone;

    final privateData = <String, dynamic>{
      'email': user.email,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (effectivePhone != null && effectivePhone.trim().isNotEmpty) {
      privateData['phone'] = normalizePhone(effectivePhone);
    }

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

    batch.set(privateRef, privateData, SetOptions(merge: true));

    if (user.email != null && user.email!.trim().isNotEmpty) {
      final normalized = normalizeEmail(user.email!);
      final hash = identityHash('email', normalized);
      batch.set(_db.collection('public_ids').doc(hash), {
        'uid': user.uid,
        'kind': 'email',
        'ownerUid': user.uid,
      });
    }

    if (effectivePhone != null && effectivePhone.trim().isNotEmpty) {
      final normalized = normalizePhone(effectivePhone);
      final hash = identityHash('phone', normalized);
      batch.set(_db.collection('public_ids').doc(hash), {
        'uid': user.uid,
        'kind': 'phone',
        'ownerUid': user.uid,
      });
    }

    await batch.commit();
  }

  Future<String?> getRegisteredPhone(String uid) async {
    final doc = await _db.collection('private_users').doc(uid).get();
    final phone = doc.data()?['phone'] as String?;
    if (phone == null || phone.trim().isEmpty) return null;
    return phone.trim();
  }

  Future<void> registerPhoneNumber({
    required String uid,
    required String phone,
  }) async {
    final normalized = normalizePhone(phone);
    if (!isValidPhone(normalized)) {
      throw Exception('מספר הטלפון אינו תקין');
    }

    final hash = identityHash('phone', normalized);
    final publicRef = _db.collection('public_ids').doc(hash);
    final existing = await publicRef.get();
    final existingOwner = existing.data()?['ownerUid'] as String?;
    if (existing.exists && existingOwner != null && existingOwner != uid) {
      throw Exception('מספר הטלפון הזה כבר משויך למשתמש אחר');
    }

    final batch = _db.batch();
    batch.set(
      _db.collection('private_users').doc(uid),
      {
        'phone': normalized,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    batch.set(
      publicRef,
      {
        'uid': uid,
        'kind': 'phone',
        'ownerUid': uid,
      },
      SetOptions(merge: true),
    );
    await batch.commit();

    await resolvePendingFriends(uid);
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

  Future<String?> findUserUidByContact({String? phone, String? email}) {
    return findUserUidByContacts(
      phones: phone == null ? const [] : [phone],
      emails: email == null ? const [] : [email],
    );
  }

  Future<String?> findUserUidByContacts({
    Iterable<String> phones = const [],
    Iterable<String> emails = const [],
  }) async {
    final hashes = <String>{};

    for (final phone in phones) {
      if (phone.trim().isEmpty) continue;
      hashes.add(identityHash('phone', normalizePhone(phone)));
    }
    for (final email in emails) {
      if (email.trim().isEmpty) continue;
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
    List<String> phones = const [],
    List<String> emails = const [],
  }) async {
    final allPhones = <String>{
      ...phones.where((value) => value.trim().isNotEmpty),
      if (phone != null && phone.trim().isNotEmpty) phone,
    }.toList();
    final allEmails = <String>{
      ...emails.where((value) => value.trim().isNotEmpty),
      if (email != null && email.trim().isNotEmpty) email,
    }.toList();

    final friendUid = await findUserUidByContacts(
      phones: allPhones,
      emails: allEmails,
    );
    final keyMaterial = '${allPhones.join('|')}|${allEmails.join('|')}|$contactName';
    final key = sha256.convert(utf8.encode(keyMaterial)).toString().substring(0, 24);

    await _db.collection('users').doc(ownerUid).collection('friends').doc(key).set({
      'contactName': contactName,
      'phone': allPhones.isEmpty ? null : allPhones.first,
      'email': allEmails.isEmpty ? null : allEmails.first,
      'phones': allPhones,
      'emails': allEmails,
      'friendUid': friendUid,
      'state': friendUid == null ? 'pending' : 'installed',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value.whereType<String>().where((item) => item.trim().isNotEmpty).toList();
    }
    return const [];
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
      final phones = <String>{
        ..._stringList(data['phones']),
        if ((data['phone'] as String?)?.trim().isNotEmpty == true)
          data['phone'] as String,
      };
      final emails = <String>{
        ..._stringList(data['emails']),
        if ((data['email'] as String?)?.trim().isNotEmpty == true)
          data['email'] as String,
      };

      final friendUid = await findUserUidByContacts(
        phones: phones,
        emails: emails,
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
