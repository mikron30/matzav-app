# Platform permissions

## Android

The Android app requires internet, contacts and location permissions. Verify the following permissions exist in `android/app/src/main/AndroidManifest.xml` as needed by the enabled features:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.READ_CONTACTS" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

For future true background-location behavior, add the relevant background/foreground-service permissions only when the feature is implemented and accompanied by the required user disclosure and Play policy declarations.

## iOS

When building iOS, add user-facing descriptions for Contacts and Location permissions in `ios/Runner/Info.plist` and configure background location only if the production feature genuinely needs it.
