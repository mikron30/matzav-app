# Google Play internal release

This document records the first internal-testing release configuration for Matzav.

## Release artifact

- Bundle: `build/app/outputs/bundle/release/app-release.aab`
- Application ID: `com.mikron30.matzav`
- Version: `0.1.0` (`versionCode` 1)
- Target SDK: 36
- SHA-256: `D4CD39C5CBE2F894B3EAF98DD22F1E1F166798BF8193F36633AD7752FC6791D9`

The bundle was built with:

```powershell
flutter build appbundle --release `
  --dart-define=MATZAV_INTERNAL_TEST=true `
  --dart-define=MATZAV_INVITE_URL=https://play.google.com/store/apps/details?id=com.mikron30.matzav
```

`MATZAV_INTERNAL_TEST=true` exposes only Google sign-in. The internal Firebase rules allow the app account `mikron30@gmail.com` and expire on 2026-10-01.

## One-time Play Console setup

1. In Google Play Console, create an app named **Matzav** with Hebrew as the default language, type **App**, and pricing **Free**.
2. Open **Test and release > Testing > Internal testing** and create a release.
3. Enable Google Play App Signing and upload `app-release.aab`.
4. Use release name `0.1.0-internal.1` and release notes `גרסת בדיקה פנימית ראשונה של Matzav.`
5. Save, review, and start the internal-testing rollout (or submit it for review if Play Console requires review).
6. On the **Testers** tab, add the Google account used by Google Play on the test phone, then open the opt-in link on that phone.

## Required after the first upload

Open **Test and release > Setup > App integrity > App signing** and copy the Play **app-signing certificate** SHA-1 and SHA-256 fingerprints. These are different from the upload-key fingerprints. Register both fingerprints with the Firebase Android app before testing Google sign-in.

The upload key is stored locally in:

- `android/upload-keystore.jks`
- `android/key.properties`

Both files are ignored by Git. Back them up together in a secure password manager or encrypted backup. Never commit either file.

Every later Play upload must use a higher `versionCode` in `pubspec.yaml` (for example, change `+1` to `+2`).
