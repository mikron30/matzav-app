# Matzav Version 18 - Tap to call

## What changed
- Tapping a friend card starts a phone call on Android.
- The first direct call asks for Android's CALL_PHONE runtime permission.
- A call icon is shown when a phone number is available.
- Pending contacts can also be called when a stored phone number exists.
- When a user explicitly adds a Matzav friend, the adding user's registered phone can be shared with that confirmed friend so both sides can call.
- Existing Version 14/17 explicit contact selections are migrated by detecting their stored contact identity data.
- Reverse-generated friendships are marked so later sync does not expose the other user's registered phone unless that user explicitly selected the contact too.
- Firestore rules validate that a cross-user phone value equals the authenticated user's own registered phone.
- Privacy policy updated for the friend calling feature.
- Build number: 18.

## Before testing
Deploy Firestore rules:

firebase deploy --only firestore:rules --project matsav-app

Then build Version 18 with the existing production AdMob build script.
