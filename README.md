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

## iOS without a local Mac

The repository contains a Codemagic workflow in `codemagic.yaml`. The iOS production bundle ID is `com.mikron30.matzav`.

Before the first iOS build:

1. Register `com.mikron30.matzav` as a new Apple app in the same Firebase project.
2. Enable Google and Apple providers in Firebase Authentication.
3. Add `GoogleService-Info.plist` to Codemagic as the base64 secret `GOOGLE_SERVICE_INFO_PLIST_BASE64` in the `firebase_ios` group.
4. Join the Apple Developer Program, create the App ID with Sign in with Apple enabled, and create the App Store Connect app record.
5. Add App Store Connect API credentials to Codemagic in the `appstore_credentials` group.

`scripts/prepare_ios_ci.sh` configures the Google iOS client ID/URL scheme and the iOS bundle ID during the cloud build.

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
