# Google Play release notes

Current Android package: `com.mikron30.matzav`.

For a signed release bundle, build with:

```bash
flutter clean
flutter pub get
flutter build appbundle --release
```

The generated bundle is normally located at:

`build/app/outputs/bundle/release/app-release.aab`

The current app version is controlled by `pubspec.yaml`.

Do not commit `android/upload-keystore.jks`, `android/key.properties`, Firebase local configuration files, or other signing secrets.
