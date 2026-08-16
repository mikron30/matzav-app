# Matzav

Matzav is a Flutter/Firebase app for sharing friends' current activity and availability status.

## MVP

- Email/password and Google authentication
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
