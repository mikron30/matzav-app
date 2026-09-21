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

  // Discover relationships first, then remove this user from each friend's
  // own friend list without requiring a collection-group index.
  const relationships = await db
    .collection("friendships")
    .where("members", "array-contains", uid)
    .get();

  for (const relationship of relationships.docs) {
    const members = relationship.data()?.members;
    if (!Array.isArray(members)) continue;
    const friendUid = members.find((member) => member !== uid);
    if (typeof friendUid !== "string" || friendUid.length === 0) continue;
    await deleteQuery(
      db
        .collection("users")
        .doc(friendUid)
        .collection("friends")
        .where("friendUid", "==", uid),
    );
  }

  // Remove friendship markers and old tombstones involving this user.
  if (!relationships.empty) {
    const writer = db.bulkWriter();
    for (const relationship of relationships.docs) {
      writer.delete(relationship.ref);
    }
    await writer.close();
  }
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

  // Remove one-shot notification requests created by this user. Requester
  // documents are keyed by uid, so this works without collection-group queries.
  for (const collectionName of ["call_waits", "driving_waits"]) {
    const targets = await db.collection(collectionName).listDocuments();
    const writer = db.bulkWriter();
    for (const target of targets) {
      if (target.id !== uid) {
        writer.delete(target.collection("waiters").doc(uid));
      }
    }
    await writer.close();
  }

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
