# Google Play release notes

Current Android package: `com.mikron30.matzav`.

The next Android upload is version code 14. For an internal test bundle that
uses Google's sample banner ad, build with:

```powershell
flutter clean
flutter pub get
$env:MATZAV_ADMOB_ANDROID_APP_ID = 'ca-app-pub-3940256099942544~3347511713'
flutter build appbundle --release --dart-define=MATZAV_USE_TEST_ADS=true
Remove-Item Env:MATZAV_ADMOB_ANDROID_APP_ID
```

Never promote that test-ad bundle to production. A public release must be
built with the real AdMob app and banner IDs by running
`scripts/build_android_release.ps1`; see `MONETIZATION_SETUP.md`.

The generated bundle is normally located at:

`build/app/outputs/bundle/release/app-release.aab`

The current app version is controlled by `pubspec.yaml`.

Do not commit `android/upload-keystore.jks`, `android/key.properties`, Firebase local configuration files, or other signing secrets.

## Google Play signing keys

New Play apps use quantum-ready hybrid signing. Matzav has three Play signing certificates, and all three must remain registered with Firebase/OAuth:

- Android 16 and earlier fallback: SHA-1 `B3:1F:0D:5F:2E:28:67:1F:97:C2:C0:D3:CA:CB:08:9E:0A:7C:3F:66`; SHA-256 `54:C6:14:77:4F:E6:61:56:E4:C1:22:24:04:70:71:28:96:A5:B2:2B:94:58:D2:29:42:2D:FA:35:93:AE:79:86`.
- Android 17+ hybrid classical: SHA-1 `79:C0:3C:90:89:64:E7:B5:B4:E6:82:96:9B:9C:C5:80:E6:1F:C1:3D`; SHA-256 `27:C9:CA:BD:6F:B5:B0:07:C3:1A:04:9B:E2:D0:E6:E4:C5:38:2D:FC:45:08:44:13:59:01:1A:29:19:6D:F6:DE`.
- Android 17+ hybrid post-quantum: SHA-1 `EB:C5:24:2E:6E:02:E2:EC:EC:8B:14:62:9B:70:E1:D2:88:B0:0B:08`; SHA-256 `59:7A:5F:37:A6:26:41:F8:4F:25:5D:5D:8E:87:EB:C4:E9:C5:56:F7:CC:58:F0:1C:C2:12:BE:03:3F:82:61:65`.

The missing fallback and post-quantum pairs were registered on 2026-08-21. Refresh `android/app/google-services.json` after any future signing-key change. No application release is needed for a fingerprint-only OAuth update when the embedded Web client ID is unchanged.
