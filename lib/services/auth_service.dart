import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  AuthService._();
  static final instance = AuthService._();

  static const String _googleWebClientId =
      '132247657839-84uo29ln5gj71g3ajm8t6f325ukair68.apps.googleusercontent.com';

  final FirebaseAuth _auth = FirebaseAuth.instance;
  GoogleSignIn? _googleSignIn;

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  GoogleSignIn get _google {
    return _googleSignIn ??= GoogleSignIn(
      serverClientId:
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android
              ? _googleWebClientId
              : null,
    );
  }

  Future<UserCredential> signInWithEmail(String email, String password) {
    return _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<UserCredential> registerWithEmail(String email, String password) {
    return _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  Future<UserCredential> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await _google.signIn();
    if (googleUser == null) {
      throw Exception('Google sign-in was canceled.');
    }

    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
      accessToken: googleAuth.accessToken,
    );
    return _auth.signInWithCredential(credential);
  }

  Future<UserCredential> signInWithApple() {
    final provider = AppleAuthProvider();
    provider.addScope('email');
    provider.addScope('name');
    return _auth.signInWithProvider(provider);
  }

  Future<void> signOut() async {
    await _auth.signOut();
    try {
      await _google.signOut();
    } catch (_) {}
  }
}
