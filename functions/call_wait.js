const {onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {onInit} = require("firebase-functions/v2/core");
const {logger} = require("firebase-functions");
const admin = require("firebase-admin");

// IMPORTANT:
// Do not initialize Firebase Admin / Firestore in global scope.
// Firebase CLI executes global-scope code while discovering functions during deploy.
// onInit() runs only in the deployed runtime, which avoids discovery timeouts.
let db = null;

onInit(() => {
  if (admin.apps.length === 0) {
    admin.initializeApp();
  }
  db = admin.firestore();
});

function firestoreDb() {
  // Defensive fallback for local/emulator execution.
  if (admin.apps.length === 0) {
    admin.initializeApp();
  }
  db ??= admin.firestore();
  return db;
}

/**
 * One-shot wait:
 * When a user explicitly taps "wait for call to end" for a friend whose
 * activity is onCall, a waiter document is created.
 *
 * When the target profile leaves activity=onCall, send an FCM push to all
 * waiters, then delete each waiter so it fires only once.
 */
exports.notifyCallWaiters = onDocumentUpdated(
  {
    document: "profiles/{targetUid}",
    maxInstances: 10,
  },
  async (event) => {
    const before = event.data?.before?.data() || {};
    const after = event.data?.after?.data() || {};

    // Only react to the transition: onCall -> anything else.
    if (before.activity !== "onCall" || after.activity === "onCall") {
      return;
    }

    const targetUid = event.params.targetUid;
    const targetName =
      String(after.displayName || before.displayName || "החבר").trim() ||
      "החבר";

    const database = firestoreDb();
    const waitersRef = database
      .collection("call_waits")
      .doc(targetUid)
      .collection("waiters");

    const waiters = await waitersRef.get();
    if (waiters.empty) {
      return;
    }

    const jobs = waiters.docs.map(async (waiterDoc) => {
      const waiterUid = waiterDoc.id;
      const requestedName =
        String(waiterDoc.data()?.targetName || targetName).trim() || targetName;

      try {
        const privateUser = await database
          .collection("private_users")
          .doc(waiterUid)
          .get();

        const token = privateUser.data()?.fcmToken;

        if (typeof token === "string" && token.length > 0) {
          await admin.messaging().send({
            token,
            notification: {
              title: "Matzav",
              body: `${requestedName} סיים/ה את השיחה`,
            },
            data: {
              type: "call_finished",
              targetUid,
              targetName: requestedName,
            },
            android: {
              priority: "high",
              notification: {
                sound: "default",
              },
            },
            apns: {
              payload: {
                aps: {
                  sound: "default",
                },
              },
            },
          });
        } else {
          logger.warn("No FCM token for call waiter", {
            waiterUid,
            targetUid,
          });
        }
      } catch (error) {
        logger.error("Failed to notify call waiter", {
          waiterUid,
          targetUid,
          error: error?.message || String(error),
        });
      } finally {
        // One request = one notification opportunity.
        await waiterDoc.ref.delete().catch(() => {});
      }
    });

    await Promise.all(jobs);
  },
);
