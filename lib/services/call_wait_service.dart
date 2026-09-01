import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

typedef _ProfileSubscription =
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>;

class CallWaitService {
  CallWaitService._();
  static final instance = CallWaitService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final StreamController<String> _foregroundMessages =
      StreamController<String>.broadcast();

  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  final Map<String, _ProfileSubscription> _statusSubscriptions = {};
  final Map<String, DateTime> _lastStatusNotice = {};
  String? _uid;

  Stream<String> get foregroundMessages => _foregroundMessages.stream;

  /// Initializes FCM listeners without forcing a notification permission
  /// prompt. Permission is requested only when the user explicitly chooses
  /// one of the wait-for-status notification buttons for the first time.
  Future<void> initializeForUser(String uid) async {
    _uid = uid;
    final messaging = FirebaseMessaging.instance;

    final currentSettings = await messaging.getNotificationSettings();
    if (_canNotify(currentSettings.authorizationStatus)) {
      final token = await messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _saveToken(uid, token);
      }
    }

    await _tokenSubscription?.cancel();
    _tokenSubscription = messaging.onTokenRefresh.listen((newToken) {
      unawaited(_saveToken(uid, newToken));
    });

    await _messageSubscription?.cancel();
    _messageSubscription = FirebaseMessaging.onMessage.listen((message) {
      final body = message.notification?.body?.trim();
      if (body == null || body.isEmpty) return;

      final type = message.data['type']?.toString();
      final targetUid = message.data['targetUid']?.toString() ?? '';
      if (type == 'call_finished') {
        _emitStatusNotice('call:$targetUid', body);
      } else if (type == 'driving_started') {
        _emitStatusNotice('drive:$targetUid', body);
      } else {
        _foregroundMessages.add(body);
      }
    });
  }

  bool _canNotify(AuthorizationStatus status) {
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }

  Future<String> _ensureNotificationPermission(String uid) async {
    final messaging = FirebaseMessaging.instance;
    var settings = await messaging.getNotificationSettings();
    if (!_canNotify(settings.authorizationStatus)) {
      settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    }
    if (!_canNotify(settings.authorizationStatus)) {
      throw StateError('כדי לקבל התראה צריך לאשר ל־Matzav לשלוח התראות.');
    }

    final token = await messaging.getToken();
    if (token == null || token.isEmpty) {
      throw StateError('לא ניתן כרגע ליצור מזהה להתראות. נסה שוב בעוד רגע.');
    }
    await _saveToken(uid, token);
    return token;
  }

  Future<void> _saveToken(String uid, String token) async {
    if (_uid != uid) return;
    await _db.collection('private_users').doc(uid).set({
      'fcmToken': token,
      'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<bool> waitForCallEnd({
    required String requesterUid,
    required String targetUid,
    required String targetName,
  }) async {
    final token = await _ensureNotificationPermission(requesterUid);

    final targetRef = _db.collection('profiles').doc(targetUid);
    final waitRef = _db
        .collection('call_waits')
        .doc(targetUid)
        .collection('waiters')
        .doc(requesterUid);

    final waiting = await _db.runTransaction<bool>((transaction) async {
      final target = await transaction.get(targetRef);
      final activity = target.data()?['activity']?.toString();
      if (activity != 'onCall') return false;

      transaction.set(waitRef, {
        'requesterUid': requesterUid,
        'targetUid': targetUid,
        'targetName': targetName,
        'fcmToken': token,
        'deliveryStatus': 'waiting',
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    });

    if (waiting) {
      _watchCallEnd(targetUid: targetUid, targetName: targetName);
    }
    return waiting;
  }

  Future<bool> waitForDrivingStart({
    required String requesterUid,
    required String targetUid,
    required String targetName,
  }) async {
    final token = await _ensureNotificationPermission(requesterUid);

    final targetRef = _db.collection('profiles').doc(targetUid);
    final waitRef = _db
        .collection('driving_waits')
        .doc(targetUid)
        .collection('waiters')
        .doc(requesterUid);

    final waiting = await _db.runTransaction<bool>((transaction) async {
      final target = await transaction.get(targetRef);
      final activity = target.data()?['activity']?.toString();
      if (activity == 'driving') return false;

      transaction.set(waitRef, {
        'requesterUid': requesterUid,
        'targetUid': targetUid,
        'targetName': targetName,
        'fcmToken': token,
        'deliveryStatus': 'waiting',
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    });

    if (waiting) {
      _watchDrivingStart(targetUid: targetUid, targetName: targetName);
    }
    return waiting;
  }

  void _watchCallEnd({required String targetUid, required String targetName}) {
    final key = 'call:$targetUid';
    unawaited(_statusSubscriptions.remove(key)?.cancel());

    var sawActiveCall = false;
    final subscription = _db
        .collection('profiles')
        .doc(targetUid)
        .snapshots()
        .listen((snapshot) {
          final activity = snapshot.data()?['activity']?.toString();
          if (activity == 'onCall') {
            sawActiveCall = true;
            return;
          }

          if (sawActiveCall || snapshot.exists) {
            _emitStatusNotice(key, '$targetName סיים/ה את השיחה');
            unawaited(_statusSubscriptions.remove(key)?.cancel());
          }
        });

    _statusSubscriptions[key] = subscription;
  }

  void _watchDrivingStart({
    required String targetUid,
    required String targetName,
  }) {
    final key = 'drive:$targetUid';
    unawaited(_statusSubscriptions.remove(key)?.cancel());

    final subscription = _db
        .collection('profiles')
        .doc(targetUid)
        .snapshots()
        .listen((snapshot) {
          final activity = snapshot.data()?['activity']?.toString();
          if (activity != 'driving') return;

          _emitStatusNotice(key, '$targetName התחיל/ה לנסוע');
          unawaited(_statusSubscriptions.remove(key)?.cancel());
        });

    _statusSubscriptions[key] = subscription;
  }

  void _emitStatusNotice(String dedupeKey, String message) {
    final now = DateTime.now();
    final previous = _lastStatusNotice[dedupeKey];
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 15)) {
      return;
    }
    _lastStatusNotice[dedupeKey] = now;
    _foregroundMessages.add(message);
  }

  Future<void> cancelWait({
    required String requesterUid,
    required String targetUid,
  }) async {
    await _statusSubscriptions.remove('call:$targetUid')?.cancel();
    await _db
        .collection('call_waits')
        .doc(targetUid)
        .collection('waiters')
        .doc(requesterUid)
        .delete();
  }

  Future<void> cancelDrivingWait({
    required String requesterUid,
    required String targetUid,
  }) async {
    await _statusSubscriptions.remove('drive:$targetUid')?.cancel();
    await _db
        .collection('driving_waits')
        .doc(targetUid)
        .collection('waiters')
        .doc(requesterUid)
        .delete();
  }

  Stream<bool> waitingStream({
    required String requesterUid,
    required String targetUid,
  }) {
    return _waiterStream(
      collection: 'call_waits',
      requesterUid: requesterUid,
      targetUid: targetUid,
    );
  }

  Stream<bool> drivingWaitingStream({
    required String requesterUid,
    required String targetUid,
  }) {
    return _waiterStream(
      collection: 'driving_waits',
      requesterUid: requesterUid,
      targetUid: targetUid,
    );
  }

  Stream<bool> _waiterStream({
    required String collection,
    required String requesterUid,
    required String targetUid,
  }) {
    return _db
        .collection(collection)
        .doc(targetUid)
        .collection('waiters')
        .doc(requesterUid)
        .snapshots()
        .map((snapshot) {
          if (!snapshot.exists) return false;
          return snapshot.data()?['deliveryStatus'] != 'failed';
        });
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    for (final subscription in _statusSubscriptions.values) {
      await subscription.cancel();
    }
    _statusSubscriptions.clear();
    _lastStatusNotice.clear();
    _tokenSubscription = null;
    _messageSubscription = null;
    _uid = null;
  }
}
