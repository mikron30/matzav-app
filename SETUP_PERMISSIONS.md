# Platform permissions

## Android: android/app/src/main/AndroidManifest.xml
Add under `<manifest>`:

```xml
<uses-permission android:name="android.permission.READ_CONTACTS" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
```

For production Android 13+ / 14+, request background location in a user-friendly staged flow and explain why it is needed.

## iOS: ios/Runner/Info.plist
Add:

```xml
<key>NSContactsUsageDescription</key>
<string>אנחנו מציגים את אנשי הקשר רק כדי שתוכל לבחור חברים להוספה.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>המיקום משמש לזיהוי נסיעה ואזורים שהגדרת.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>המיקום משמש לעדכון מצב אוטומטי גם כשהאפליקציה ברקע.</string>
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
</array>
```

In Xcode enable Background Modes > Location updates.
