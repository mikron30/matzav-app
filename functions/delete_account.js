const {onRequest} = require("firebase-functions/v2/https");
const {logger} = require("firebase-functions");
const admin = require("firebase-admin");

function ensureAdmin() {
  if (admin.apps.length === 0) {
    admin.initializeApp();
  }
}

async function deleteQuery(query) {
  const snapshot = await query.get();
  if (snapshot.empty) return 0;

  const writer = admin.firestore().bulkWriter();
  for (const doc of snapshot.docs) {
    writer.delete(doc.ref);
  }
  await writer.close();
  return snapshot.size;
}

async function deleteAccountData(uid) {
  const db = admin.firestore();

  // Remove references to this user from other users' friend lists.
  await deleteQuery(
    db.collectionGroup("friends").where("friendUid", "==", uid),
  );

  // Remove friendship markers and old tombstones involving this user.
  await deleteQuery(
    db.collection("friendships").where("members", "array-contains", uid),
  );
  await deleteQuery(
    db.collection("friendship_tombstones").where(
      "members",
      "array-contains",
      uid,
    ),
  );

  // Remove public lookup hashes that belong to this account.
  await deleteQuery(
    db.collection("public_ids").where("ownerUid", "==", uid),
  );

  // Remove one-shot notification requests created by this user.
  await deleteQuery(
    db.collectionGroup("waiters").where("requesterUid", "==", uid),
  );

  // Remove the user's own data, including nested friends and waiter queues
  // where this user was the notification target.
  await Promise.all([
    db.recursiveDelete(db.collection("users").doc(uid)),
    db.recursiveDelete(db.collection("call_waits").doc(uid)),
    db.recursiveDelete(db.collection("driving_waits").doc(uid)),
  ]);

  await Promise.all([
    db.collection("profiles").doc(uid).delete(),
    db.collection("private_users").doc(uid).delete(),
  ]);
}

exports.deleteAccount = onRequest(
  {region: "us-central1"},
  async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).json({error: "method_not_allowed"});
      return;
    }

    ensureAdmin();

    const authHeader = request.get("authorization") || "";
    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    if (!match) {
      response.status(401).json({error: "missing_auth"});
      return;
    }

    let uid;
    try {
      const decoded = await admin.auth().verifyIdToken(match[1], true);
      uid = decoded.uid;
    } catch (error) {
      logger.warn("Account deletion rejected: invalid auth token", {
        code: error?.code,
      });
      response.status(401).json({error: "invalid_auth"});
      return;
    }

    try {
      await deleteAccountData(uid);
      await admin.auth().deleteUser(uid);
      logger.info("Matzav account deleted", {uid});
      response.status(200).json({ok: true});
    } catch (error) {
      logger.error("Failed to delete Matzav account", {
        uid,
        error: error?.message || String(error),
        code: error?.code,
      });
      response.status(500).json({error: "delete_failed"});
    }
  },
);
