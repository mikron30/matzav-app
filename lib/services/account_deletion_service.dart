import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

class AccountDeletionService {
  AccountDeletionService._();
  static final instance = AccountDeletionService._();

  Future<void> deleteCurrentAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('אין משתמש מחובר.');
    }

    final token = await user.getIdToken(true);
    if (token == null || token.isEmpty) {
      throw StateError('לא ניתן לאמת את החשבון.');
    }

    final projectId = Firebase.app().options.projectId;
    final uri = Uri.https(
      'us-central1-$projectId.cloudfunctions.net',
      '/deleteAccount',
    );

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      request.add(utf8.encode('{}'));

      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      if (response.statusCode != HttpStatus.ok) {
        String message = 'מחיקת החשבון נכשלה. נסה שוב מאוחר יותר.';
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['error'] == 'invalid_auth') {
            message = 'האימות פג. צא מהחשבון, התחבר מחדש ונסה שוב.';
          }
        } catch (_) {}
        throw HttpException(message, uri: uri);
      }

      // The server removes Firebase Authentication last. Clear the local
      // session as well so the app returns immediately to the sign-in screen.
      await FirebaseAuth.instance.signOut();
    } finally {
      client.close(force: true);
    }
  }
}
