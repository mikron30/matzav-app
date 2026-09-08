# Android background driving — version 0.1.0+44

The driving detector is intended to continue when the user closes the app
normally, opens another app, or locks the screen. It uses Google Play services'
IN_VEHICLE transitions and a manifest receiver, independently of the Flutter UI.
This update concerns Android; it does not add native background driving to iOS.

## Problems fixed from version 43

- The transition PendingIntent was immutable, so Play services could not attach
  the event data. The new intent is mutable and explicitly targets our receiver;
  the old subscription is removed during migration.
- Physical Activity permission was requested only for sleep. Driving now requests
  it independently, including when calls and sleep are both disabled.
- Registration is retried immediately after the permission response and on app
  resume, authenticated startup, reboot and package replacement.
- Native monitoring starts before GPS setup, so a location permission/service
  failure cannot prevent registration of vehicle transitions.
- The receiver persists the latest state and durably enqueues WorkManager work.
  It no longer keeps a broadcast open while waiting indefinitely for Firestore.
- Network-constrained work retries after connectivity returns. Serialized workers
  read the latest state; account and revision checks reject stale work.
- Status restoration respects call/sleep priority, later manual activity changes,
  and expired meeting/DND timers. GPS slow samples cannot override an active
  IN_VEHICLE event at a traffic light.

No new Firestore rules or cloud function deployment is needed for this change.

## Install and check on a phone

1. Build and install Android version **0.1.0+44**, using the existing Firebase
   configuration and signing setup. See `scripts/build_android_release.ps1` and
   `MONETIZATION_SETUP.md`. GitHub Pages is only the public site/privacy policy.
2. Open Matzav once, sign in, enable driving detection, and allow the Android
   **Physical Activity / פעילות גופנית** permission. Driving does not require
   enabling sleep detection. Google Play services must be available.
3. Close the app normally or lock the screen before starting a trip. From a
   friend's phone, watch for the status to become **בנסיעה**. Vehicle recognition
   is sensor-based and is not instantaneous; do not infer failure after seconds.
4. End the trip and leave the vehicle; verify restoration on the friend's phone.
5. Repeat with sleep disabled. Also check a call during the trip and a short
   network interruption; publishing must resume when connectivity returns.
6. If detection still stalls on Samsung, check the app's Physical Activity
   permission and that it has not been placed in the device's sleeping/deep
   sleeping apps list. Record which version and permissions were installed.

Android battery restrictions and recognition accuracy still affect delivery.
Force stop and uninstall are outside this normal-close scenario.

## Validation

Run the actual production status-decision code on a JDK 17+ machine:

```sh
python scripts/test_driving_policy.py
```

This compiles the Java policy with warnings treated as errors and runs 29 checks:
permissions, entry/exit, idempotence, manual activity preservation, call/sleep
priority, timer restoration, final-state processing after offline events, and
account/revision isolation. It does not simulate Android sensor delivery.

With the complete Flutter/Firebase build environment, also run:

```sh
flutter test test/automation_preferences_test.dart
flutter analyze
```

The JVM checks were run during development. Flutter analysis, a signed Android
build, and an on-device trip were not run in the editing environment; these
remain required release/device checks.

## Platform references

- [Android transition API](https://developer.android.com/develop/sensors-and-location/location/transitions)
- [PendingIntent mutability](https://developer.android.com/reference/android/app/PendingIntent#FLAG_IMMUTABLE)
- [Persistent background work](https://developer.android.com/develop/background-work/background-tasks/persistent)
