// File generated for Matzav Firebase configuration.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'DefaultFirebaseOptions have not been configured for web.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported on this platform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBDhIqFMlysik6MyiKBmHsKP-Rip1_k40k',
    appId: '1:132247657839:android:6552df2485b80d55bedc9a',
    messagingSenderId: '132247657839',
    projectId: 'matsav-app',
    storageBucket: 'matsav-app.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBDhIqFMlysik6MyiKBmHsKP-Rip1_k40k',
    appId: '1:132247657839:ios:61cacdbf9a60c55ebedc9a',
    messagingSenderId: '132247657839',
    projectId: 'matsav-app',
    storageBucket: 'matsav-app.firebasestorage.app',
    iosClientId:
        '132247657839-7fk2o8ehvuboi4jf8ceidem36ohu6st9.apps.googleusercontent.com',
    iosBundleId: 'com.mikron30.matzav',
  );
}
