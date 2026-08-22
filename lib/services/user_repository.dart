import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/friend_access_policy.dart';
import '../models/status_models.dart';

class UserRepository {
  UserRepository._();
  static final instance = UserRepository._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  static const String defaultCountryCode = '972';
  static const int maxFriendIdentitiesPerType = 20;
  static const int maxFriendPhotoBytes = 96 * 1024;

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
    batch.set(profileRef, {
      'uid': user.uid,
      'displayName': displayName,
      'photoUrl': user.photoURL,
      'activity': existing.data()?['activity'] ?? ActivityStatus.home.name,
      'availability':
          existing.data()?['availability'] ?? AvailabilityStatus.canTalk.name,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

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
    batch.set(_db.collection('private_users').doc(uid), {
      'phone': normalized,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batch.set(publicRef, {
      'uid': uid,
      'kind': 'phone',
      'ownerUid': uid,
    }, SetOptions(merge: true));
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
    final data = <String, dynamic>{'updatedAt': FieldValue.serverTimestamp()};
    if (activity != null) data['activity'] = activity.name;
    if (availability != null) data['availability'] = availability.name;
    await _db
        .collection('profiles')
        .doc(uid)
        .set(data, SetOptions(merge: true));
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> friendsStream(String uid) {
    return _db
        .collection('users')
        .doc(uid)
        .collection('friends')
        .orderBy('contactName')
        .snapshots();
  }

  Future<int> getFriendCount(String uid) async {
    final snapshot = await _db
        .collection('users')
        .doc(uid)
        .collection('friends')
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  Future<void> removeFriend({
    required String ownerUid,
    required String friendId,
  }) {
    return _db
        .collection('users')
        .doc(ownerUid)
        .collection('friends')
        .doc(friendId)
        .delete();
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

  Future<bool> addFriendContact({
    required String ownerUid,
    required String contactName,
    String? phone,
    String? email,
    List<String> phones = const [],
    List<String> emails = const [],
    Uint8List? contactPhoto,
    int? maxFriends,
  }) async {
    final allPhones = <String>{
      ...phones.where((value) => value.trim().isNotEmpty).map(normalizePhone),
      if (phone != null && phone.trim().isNotEmpty) normalizePhone(phone),
    }.toList()..sort();
    if (allPhones.length > maxFriendIdentitiesPerType) {
      allPhones.removeRange(maxFriendIdentitiesPerType, allPhones.length);
    }
    final allEmails = <String>{
      ...emails.where((value) => value.trim().isNotEmpty).map(normalizeEmail),
      if (email != null && email.trim().isNotEmpty) normalizeEmail(email),
    }.toList()..sort();
    if (allEmails.length > maxFriendIdentitiesPerType) {
      allEmails.removeRange(maxFriendIdentitiesPerType, allEmails.length);
    }

    if (allPhones.isEmpty && allEmails.isEmpty) {
      throw const InvalidFriendContactException(
        'לאיש הקשר אין מספר טלפון או כתובת אימייל.',
      );
    }

    final keyMaterial =
        'phones:${allPhones.join('|')}|emails:${allEmails.join('|')}';
    final key = sha256
        .convert(utf8.encode(keyMaterial))
        .toString()
        .substring(0, 24);
    final friendsRef = _db
        .collection('users')
        .doc(ownerUid)
        .collection('friends');
    var friendRef = friendsRef.doc(key);
    DocumentSnapshot<Map<String, dynamic>> existing = await friendRef.get();

    if (!existing.exists) {
      // Version 12 included the contact name and unnormalized identities in
      // the document ID. Match those records by identity so selecting the
      // same person after upgrading updates the existing record instead of
      // creating a duplicate that consumes another free slot.
      final currentFriends = await friendsRef.get();
      QueryDocumentSnapshot<Map<String, dynamic>>? legacyMatch;
      for (final candidate in currentFriends.docs) {
        if (_friendMatchesIdentity(candidate.data(), allPhones, allEmails)) {
          legacyMatch = candidate;
          break;
        }
      }
      if (legacyMatch != null) {
        friendRef = legacyMatch.reference;
        existing = legacyMatch;
      } else if (maxFriends != null &&
          currentFriends.docs.length >= maxFriends) {
        throw const FriendLimitReachedException();
      }
    }

    final friendUid = await findUserUidByContacts(
      phones: allPhones,
      emails: allEmails,
    );
    if (friendUid == ownerUid) {
      throw const InvalidFriendContactException(
        'אי אפשר להוסיף את עצמך לרשימת החברים.',
      );
    }

    final data = <String, dynamic>{
      'contactName': contactName.trim().isEmpty ? 'ללא שם' : contactName.trim(),
      'phone': allPhones.isEmpty ? null : allPhones.first,
      'email': allEmails.isEmpty ? null : allEmails.first,
      'phones': allPhones,
      'emails': allEmails,
      'friendUid': friendUid,
      'state': friendUid == null ? 'pending' : 'installed',
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (contactPhoto != null &&
        contactPhoto.isNotEmpty &&
        contactPhoto.length <= maxFriendPhotoBytes) {
      data['contactPhoto'] = Blob(Uint8List.fromList(contactPhoto));
    }
    if (!existing.exists) data['createdAt'] = FieldValue.serverTimestamp();
    await friendRef.set(data, SetOptions(merge: true));
    return !existing.exists;
  }

  bool _friendMatchesIdentity(
    Map<String, dynamic> friend,
    Iterable<String> normalizedPhones,
    Iterable<String> normalizedEmails,
  ) {
    final storedPhones = <String>{
      ..._stringList(friend['phones']),
      if ((friend['phone'] as String?)?.trim().isNotEmpty == true)
        friend['phone'] as String,
    }.map(normalizePhone).toSet();
    final storedEmails = <String>{
      ..._stringList(friend['emails']),
      if ((friend['email'] as String?)?.trim().isNotEmpty == true)
        friend['email'] as String,
    }.map(normalizeEmail).toSet();

    return normalizedPhones.any(storedPhones.contains) ||
        normalizedEmails.any(storedEmails.contains);
  }

  List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .whereType<String>()
          .where((item) => item.trim().isNotEmpty)
          .toList();
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
        try {
          await doc.reference.update({
            'friendUid': friendUid,
            'state': 'installed',
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } on FirebaseException catch (error) {
          // The owner may remove a pending friend while resolution is running.
          if (error.code != 'not-found') rethrow;
        }
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
        name: {'lat': latitude, 'lng': longitude, 'radius': radiusMeters},
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
