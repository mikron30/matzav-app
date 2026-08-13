# Matzav

Flutter + Firebase MVP for sharing **activity** and **call availability** with selected friends.

The app is designed around two independent status dimensions:

- **Activity:** home, work, meeting, driving, dog walk.
- **Availability:** free to talk, can talk, do not disturb.

Friends who have the app can see each other's current status in real time. Friends who are not registered yet can be invited from the phone share sheet.

## MVP features

- Email/password authentication.
- Google Sign-In.
- Phone authentication with Firebase OTP.
- Select multiple friends from the device contacts list.
- Only explicitly selected contacts are stored; the full address book is never uploaded.
- Match an existing Matzav user using SHA-256 identifiers derived from normalized phone/email.
- Pending friend state when the selected contact has not joined yet.
- Invite sharing through the device share sheet (WhatsApp/SMS/email apps can be selected by the user).
- Real-time friend status via Cloud Firestore.
- Manual activity and availability selection.
- Automatic driving mode using GPS speed samples.
- User-defined Home, Work and Dog Walk location zones.

## Repository status

This repository contains the Dart/Flutter application source and Firebase security rules. Android and iOS runner folders are intentionally generated locally with Flutter so the project can start from the installed Flutter version on the developer machine.

No Firebase project configuration, signing keys, passwords or other secrets are committed.

## Quick start

### 1. Install prerequisites

Install:

- Flutter SDK
- Android Studio / Android SDK for Android development
- Xcode on macOS for iOS development
- Firebase CLI and FlutterFire CLI when configuring Firebase

### 2. Clone the repository

```bash
git clone https://github.com/mikron30/matzav-app.git
cd matzav-app
```

### 3. Generate Android/iOS runner folders

Windows PowerShell:

```powershell
./scripts/bootstrap.ps1
```

macOS/Linux:

```bash
./scripts/bootstrap.sh
```

Equivalent manual command:

```bash
flutter create . --platforms=android,ios
flutter pub get
```

### 4. Configure Firebase

Create a Firebase project and enable:

- Authentication: Email/Password
- Authentication: Phone
- Authentication: Google
- Cloud Firestore

Then configure the Flutter app with your Firebase project. A convenient route is:

```bash
flutterfire configure
```

Project-specific Firebase files are excluded by `.gitignore`.

For Android Google Sign-In and Phone Auth, also add your Android SHA-1/SHA-256 fingerprints in Firebase.

### 5. Apply mobile permissions

Follow [`SETUP_PERMISSIONS.md`](SETUP_PERMISSIONS.md) for contacts, location and background-location requirements.

### 6. Deploy Firestore rules

Deploy [`firestore.rules`](firestore.rules) to the Firebase project before testing with real users.

### 7. Run

```bash
flutter pub get
flutter run
```

## Invite URL

The MVP defaults to a placeholder invite URL. Override it at build/run time:

```bash
flutter run --dart-define=MATZAV_INVITE_URL=https://your-real-install-link.example
```

Later this can point to a universal/app link that routes to Google Play or the App Store.

## Privacy model

- The app reads contacts locally only after permission is granted.
- Only contacts selected by the user are saved.
- Public profile/status documents do not contain raw phone numbers or email addresses.
- Raw identity and location-zone data live under each user's private Firestore document.
- Contact matching uses SHA-256 lookup documents and Firestore rules deny collection listing.

The hashing mechanism is useful for reducing accidental disclosure, but it is **not** a substitute for a stronger privacy-preserving contact-discovery backend for a production app. Phone numbers have a small search space, so a production design should consider server-side protected matching rather than treating hashes as secret.

## Automatic status behavior

Current MVP automation:

- Two speed samples at roughly 20 km/h or above switch activity to **Driving**.
- Three slow samples leave Driving mode.
- At low speed, saved Home / Work / Dog Walk zones can update activity.

Planned improvement: Android Activity Recognition + car Bluetooth detection, and iOS Core Motion / appropriate vehicle signals, to reduce continuous GPS use and improve accuracy.

## Invitations

The MVP uses the operating system share sheet. It does **not** silently send WhatsApp or SMS messages. Fully automated SMS needs a backend/provider. Automated WhatsApp messaging requires the WhatsApp Business Platform, approved templates where applicable, and user opt-in.

## Security

Do not commit:

- `android/app/google-services.json`
- `ios/Runner/GoogleService-Info.plist`
- `lib/firebase_options.dart`
- signing keys / keystores
- `.env` files containing secrets

Review Firestore rules and privacy behavior again before production release.
