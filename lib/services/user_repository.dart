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

  String _friendshipId(String uidA, String uidB) {
    final members = [uidA, uidB]..sort();
    return sha256
        .convert(utf8.encode('friendship:${members[0]}|${members[1]}'))
        .toString();
  }

  String _installedFriendDocId(String friendUid) {
    return sha256
        .convert(utf8.encode('installed:$friendUid'))
        .toString()
        .substring(0, 24);
  }

  List<String> _sortedMembers(String uidA, String uidB) {
    return [uidA, uidB]..sort();
  }

  DocumentReference<Map<String, dynamic>> _friendRef(
    String ownerUid,
    String friendId,
  ) {
    return _db
        .collection('users')
        .doc(ownerUid)
        .collection('friends')
        .doc(friendId);
  }


  DocumentReference<Map<String, dynamic>> _tombstoneRef(
    String ownerUid,
    String friendUid,
  ) {
    return _db
        .collection('friendship_tombstones')
        .doc(_friendshipId(ownerUid, friendUid));
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

    await syncFriendRelationships(uid);
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
  }) async {
    final selectedRef = _friendRef(ownerUid, friendId);
    final selectedSnapshot = await selectedRef.get();
    if (!selectedSnapshot.exists) return;

    final data = selectedSnapshot.data() ?? const <String, dynamic>{};
    final friendUid = data['friendUid'] as String?;
    if (friendUid == null || friendUid.isEmpty) {
      await selectedRef.delete();
      return;
    }

    final relationshipId = _friendshipId(ownerUid, friendUid);
    final friendshipRef = _db.collection('friendships').doc(relationshipId);
    final friendshipSnapshot = await friendshipRef.get();

    // Old version-13 records may not have a shared friendship marker yet.
    // Create it first so the cross-user delete is authorized by the v14 rules.
    if (!friendshipSnapshot.exists) {
      await _upsertInstalledRelationship(
        ownerUid: ownerUid,
        friendUid: friendUid,
        ownerData: Map<String, dynamic>.from(data),
        legacyRefs: const [],
      );
    }

    final canonicalOwnerRef = _friendRef(
      ownerUid,
      _installedFriendDocId(friendUid),
    );
    final reverseRef = _friendRef(
      friendUid,
      _installedFriendDocId(ownerUid),
    );
    final tombstoneRef = _db
        .collection('friendship_tombstones')
        .doc(relationshipId);

    final batch = _db.batch();
    batch.set(tombstoneRef, {
      'members': _sortedMembers(ownerUid, friendUid),
      'deletedBy': ownerUid,
      'deletedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batch.delete(selectedRef);
    if (canonicalOwnerRef.path != selectedRef.path) {
      batch.delete(canonicalOwnerRef);
    }
    batch.delete(reverseRef);
    batch.delete(friendshipRef);
    await batch.commit();
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

    final friendUid = await findUserUidByContacts(
      phones: allPhones,
      emails: allEmails,
    );
    if (friendUid == ownerUid) {
      throw const InvalidFriendContactException(
        'אי אפשר להוסיף את עצמך לרשימת החברים.',
      );
    }

    final friendsRef = _db
        .collection('users')
        .doc(ownerUid)
        .collection('friends');
    final currentFriends = await friendsRef.get();

    if (friendUid == null) {
      return _savePendingFriend(
        ownerUid: ownerUid,
        contactName: contactName,
        allPhones: allPhones,
        allEmails: allEmails,
        contactPhoto: contactPhoto,
        maxFriends: maxFriends,
        currentFriends: currentFriends.docs,
      );
    }

    final canonicalId = _installedFriendDocId(friendUid);
    final matches = currentFriends.docs.where((candidate) {
      final candidateFriendUid = candidate.data()['friendUid'] as String?;
      return candidate.id == canonicalId ||
          candidateFriendUid == friendUid ||
          _friendMatchesIdentity(candidate.data(), allPhones, allEmails);
    }).toList();

    final created = matches.isEmpty;
    if (created &&
        maxFriends != null &&
        currentFriends.docs.length >= maxFriends) {
      throw const FriendLimitReachedException();
    }

    dynamic existingCreatedAt;
    for (final doc in matches) {
      final value = doc.data()['createdAt'];
      if (value != null) {
        existingCreatedAt = value;
        break;
      }
    }

    final ownerData = <String, dynamic>{
      'contactName': contactName.trim().isEmpty ? 'ללא שם' : contactName.trim(),
      'phone': allPhones.isEmpty ? null : allPhones.first,
      'email': allEmails.isEmpty ? null : allEmails.first,
      'phones': allPhones,
      'emails': allEmails,
      'contactSelectedByOwner': true,
      if (contactPhoto != null &&
          contactPhoto.isNotEmpty &&
          contactPhoto.length <= maxFriendPhotoBytes)
        'contactPhoto': Blob(Uint8List.fromList(contactPhoto)),
      'createdAt': existingCreatedAt ?? FieldValue.serverTimestamp(),
    };

    await _upsertInstalledRelationship(
      ownerUid: ownerUid,
      friendUid: friendUid,
      ownerData: ownerData,
      legacyRefs: matches
          .where((doc) => doc.id != canonicalId)
          .map((doc) => doc.reference)
          .toList(),
      shareOwnerPhoneWithFriend: true,
    );
    return created;
  }

  Future<bool> _savePendingFriend({
    required String ownerUid,
    required String contactName,
    required List<String> allPhones,
    required List<String> allEmails,
    required Uint8List? contactPhoto,
    required int? maxFriends,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> currentFriends,
  }) async {
    final keyMaterial =
        'phones:${allPhones.join('|')}|emails:${allEmails.join('|')}';
    final key = sha256
        .convert(utf8.encode(keyMaterial))
        .toString()
        .substring(0, 24);
    final canonicalRef = _friendRef(ownerUid, key);

    final matches = currentFriends
        .where(
          (candidate) =>
              candidate.id == key ||
              _friendMatchesIdentity(candidate.data(), allPhones, allEmails),
        )
        .toList();
    final created = matches.isEmpty;
    if (created && maxFriends != null && currentFriends.length >= maxFriends) {
      throw const FriendLimitReachedException();
    }

    final targetRef = matches.isEmpty ? canonicalRef : matches.first.reference;
    final existingCreatedAt = matches.isEmpty
        ? null
        : matches.first.data()['createdAt'];
    final data = <String, dynamic>{
      'contactName': contactName.trim().isEmpty ? 'ללא שם' : contactName.trim(),
      'phone': allPhones.isEmpty ? null : allPhones.first,
      'email': allEmails.isEmpty ? null : allEmails.first,
      'phones': allPhones,
      'emails': allEmails,
      'friendUid': null,
      'state': 'pending',
      'contactSelectedByOwner': true,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': existingCreatedAt ?? FieldValue.serverTimestamp(),
    };
    if (contactPhoto != null &&
        contactPhoto.isNotEmpty &&
        contactPhoto.length <= maxFriendPhotoBytes) {
      data['contactPhoto'] = Blob(Uint8List.fromList(contactPhoto));
    }
    await targetRef.set(data, SetOptions(merge: true));
    return created;
  }

  Future<void> _upsertInstalledRelationship({
    required String ownerUid,
    required String friendUid,
    required Map<String, dynamic> ownerData,
    required List<DocumentReference<Map<String, dynamic>>> legacyRefs,
    bool shareOwnerPhoneWithFriend = false,
  }) async {
    final relationshipId = _friendshipId(ownerUid, friendUid);
    final ownerRef = _friendRef(ownerUid, _installedFriendDocId(friendUid));
    final reverseRef = _friendRef(friendUid, _installedFriendDocId(ownerUid));
    final friendshipRef = _db.collection('friendships').doc(relationshipId);
    final tombstoneRef = _db
        .collection('friendship_tombstones')
        .doc(relationshipId);

    final ownerProfile = await _db.collection('profiles').doc(ownerUid).get();
    final ownerDisplayName =
        (ownerProfile.data()?['displayName'] as String?)?.trim();
    final reverseName = ownerDisplayName == null || ownerDisplayName.isEmpty
        ? 'חבר'
        : ownerDisplayName;

    String? ownerPhone;
    if (shareOwnerPhoneWithFriend) {
      final registeredPhone = await getRegisteredPhone(ownerUid);
      if (registeredPhone != null && isValidPhone(registeredPhone)) {
        ownerPhone = normalizePhone(registeredPhone);
      }
    }

    final tombstone = await tombstoneRef.get();

    final normalizedOwnerData = Map<String, dynamic>.from(ownerData)
      ..['friendUid'] = friendUid
      ..['state'] = 'installed'
      ..['friendshipId'] = relationshipId
      ..['updatedAt'] = FieldValue.serverTimestamp();
    if (shareOwnerPhoneWithFriend) {
      normalizedOwnerData['contactSelectedByOwner'] = true;
    }

    final batch = _db.batch();
    if (tombstone.exists) batch.delete(tombstoneRef);
    batch.set(friendshipRef, {
      'members': _sortedMembers(ownerUid, friendUid),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    batch.set(ownerRef, normalizedOwnerData, SetOptions(merge: true));
    final reverseData = <String, dynamic>{
      'contactName': reverseName,
      'friendUid': ownerUid,
      'state': 'installed',
      'friendshipId': relationshipId,
      'contactSelectedByOwner': false,
      'updatedAt': FieldValue.serverTimestamp(),
      if (ownerPhone != null) 'phone': ownerPhone,
      if (ownerPhone != null) 'phones': [ownerPhone],
    };
    batch.set(reverseRef, reverseData, SetOptions(merge: true));

    for (final legacyRef in legacyRefs) {
      if (legacyRef.path != ownerRef.path) batch.delete(legacyRef);
    }
    await batch.commit();
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

  bool _wasSelectedByOwner(Map<String, dynamic> data) {
    final marker = data['contactSelectedByOwner'];
    if (marker is bool) return marker;

    final hasPhone =
        _stringList(data['phones']).isNotEmpty ||
        ((data['phone'] as String?)?.trim().isNotEmpty == true);
    final hasEmail =
        _stringList(data['emails']).isNotEmpty ||
        ((data['email'] as String?)?.trim().isNotEmpty == true);
    final hasContactPhoto = data['contactPhoto'] != null;

    // Version 14/17 records did not have the marker. A reverse-generated
    // friendship contained only the friend's uid/name/status fields, while a
    // contact explicitly selected by the owner contained phone/email/photo
    // identity data. This safely migrates old explicit selections.
    return hasPhone || hasEmail || hasContactPhoto;
  }

  Future<void> syncFriendRelationships(String ownerUid) async {
    await resolvePendingFriends(ownerUid);
    await _syncInstalledFriendships(ownerUid);
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
      if (friendUid == null || friendUid == ownerUid) continue;

      try {
        await _upsertInstalledRelationship(
          ownerUid: ownerUid,
          friendUid: friendUid,
          ownerData: Map<String, dynamic>.from(data),
          legacyRefs: [doc.reference],
          shareOwnerPhoneWithFriend: true,
        );
      } on FirebaseException catch (error) {
        // The owner may remove a pending friend while resolution is running.
        if (error.code != 'not-found') rethrow;
      }
    }
  }

  Future<void> _syncInstalledFriendships(String ownerUid) async {
    final snapshot = await _db
        .collection('users')
        .doc(ownerUid)
        .collection('friends')
        .where('state', isEqualTo: 'installed')
        .get();

    final grouped = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final doc in snapshot.docs) {
      final friendUid = doc.data()['friendUid'] as String?;
      if (friendUid == null || friendUid.isEmpty || friendUid == ownerUid) {
        continue;
      }
      grouped.putIfAbsent(friendUid, () => []).add(doc);
    }

    for (final entry in grouped.entries) {
      final friendUid = entry.key;
      final docs = entry.value;
      final tombstone = await _tombstoneRef(ownerUid, friendUid).get();
      if (tombstone.exists) {
        final batch = _db.batch();
        for (final doc in docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
        continue;
      }

      final canonicalId = _installedFriendDocId(friendUid);
      QueryDocumentSnapshot<Map<String, dynamic>>? canonical;
      for (final doc in docs) {
        if (doc.id == canonicalId) {
          canonical = doc;
          break;
        }
      }
      final source = canonical ?? docs.first;
      final ownerData = Map<String, dynamic>.from(source.data());
      await _upsertInstalledRelationship(
        ownerUid: ownerUid,
        friendUid: friendUid,
        ownerData: ownerData,
        legacyRefs: docs
            .where((doc) => doc.id != canonicalId)
            .map((doc) => doc.reference)
            .toList(),
        shareOwnerPhoneWithFriend: _wasSelectedByOwner(ownerData),
      );
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
