# Matzav

Matzav is a Flutter/Firebase app for sharing friends' current activity and availability status.

## MVP

- Email/password and Google authentication
- Sign in with Apple on iOS
- Add selected friends from contacts
- Invite non-users through the OS share sheet
- Realtime friend status through Firestore
- Activity status: home, work, meeting, driving, dog walk
- Availability status: free to talk, can talk, do not disturb
- Optional GPS-based automatic driving/home/work detection
- Selected-contact discovery using normalized phone/email hashes

## Local setup

Platform folders are included in the repository. Firebase configuration files and signing keys are intentionally excluded.

1. Install Flutter and Firebase CLI.
2. Run `flutter pub get`.
3. Run `flutterfire configure` if Firebase options are missing.
4. Apply permissions from `SETUP_PERMISSIONS.md`.
5. Deploy `firestore.rules`.
6. Run `flutter run`.

## Google Sign-In diagnostic on Windows

The Android production package is `com.mikron30.matzav`. After downloading a fresh `android/app/google-services.json`, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\check_google_auth_config.ps1
```

The checker verifies that the file belongs to the production package and contains the required Web OAuth client (`client_type: 3`).

Google Play quantum-ready signing uses separate certificates for Android 16 and earlier and for the Android 17+ hybrid signature. The checker also verifies that all three known Play signing SHA-1 certificates have Android OAuth clients. Whenever Play rotates or adds a key, register every fingerprint shown under **Protected with Play > Play Store distribution > Play app signing** with Firebase and refresh `google-services.json`.

## iOS without a local Mac

The repository contains a Codemagic workflow in `codemagic.yaml`. The iOS production bundle ID is `com.mikron30.matzav`.

Before the first iOS build:

1. Register `com.mikron30.matzav` as a new Apple app in the same Firebase project.
2. Enable Google and Apple providers in Firebase Authentication.
3. Generate a fresh `GoogleService-Info.plist` and `lib/firebase_options.dart` for the new iOS app.
4. Add both to Codemagic as base64 secrets in the `firebase_ios` group:
   - `GOOGLE_SERVICE_INFO_PLIST_BASE64`
   - `FIREBASE_OPTIONS_DART_BASE64`
5. Join the Apple Developer Program, create the App ID with Sign in with Apple enabled, and create the App Store Connect app record.
6. Add App Store Connect API credentials to Codemagic in the `appstore_credentials` group.

`scripts/prepare_ios_ci.sh` configures the production iOS bundle ID, Sign in with Apple entitlements, and the Google iOS client ID/URL scheme during the cloud build.

## Firebase files intentionally not committed

- `android/app/google-services.json`
- `ios/Runner/GoogleService-Info.plist`
- `lib/firebase_options.dart`
- signing keys / keystore files
- `android/key.properties`

## Privacy

The public privacy policy for the Play Store is available through GitHub Pages at:

`https://mikron30.github.io/matzav-app/privacy.html`

## Security note

The MVP uses SHA-256 hashes of normalized phone numbers/emails for exact contact lookup. For production scale, contact discovery should move to a server-side service with stronger abuse protections and rate limiting.
