# Platform permissions

## Android: android/app/src/main/AndroidManifest.xml

The first Google Play test release uses contacts and location only while the app is visible. Add under `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.READ_CONTACTS" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

Do not add background-location or location foreground-service permissions until the app includes Android's staged permission flow, a prominent disclosure, a privacy policy, and the corresponding Google Play declarations.

## iOS: ios/Runner/Info.plist

The first test release also uses location only while the app is visible. Add:

```xml
<key>NSContactsUsageDescription</key>
<string>Matzav shows contacts only so you can choose friends to add.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Matzav uses your location to detect driving and zones while the app is open.</string>
```

Do not enable the iOS location background mode or add the `Always` usage descriptions until background behavior and its disclosure flow are implemented.
