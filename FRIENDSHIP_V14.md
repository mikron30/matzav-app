# Version 14 friendship behavior

Version 14 makes installed-user friendships symmetric without Cloud Functions.

- Adding an installed Matzav user creates one shared `friendships/{id}` marker.
- The same atomic Firestore batch writes a friend record for both users.
- Removing an installed friend deletes both users' records and the shared marker.
- A `friendship_tombstones/{id}` document prevents an old version-13 record from
  recreating a relationship after either participant removed it.
- Pending contacts who have not installed Matzav remain private under the adding
  user's `users/{uid}/friends` collection and are promoted automatically once an
  exact phone/email hash resolves to a registered user.

## Required before testing version 14

Deploy the version-14 Firestore rules **before** testing the new app build:

```powershell
firebase deploy --only firestore:rules
```

If the Firebase CLI is not installed globally, from the repository root use:

```powershell
npx firebase-tools deploy --only firestore:rules
```

The Firebase project is `matsav-app`. Verify that the CLI is logged into the
account that owns that project before deploying.

Both test phones should install version 14 before testing old v13 friendships.
On first open, version 14 migrates installed v13 friend records to the symmetric
relationship format. Pull-to-refresh also reruns the migration/synchronization.
