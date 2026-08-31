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

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function sendWithRetry(message, attempts = 3) {
  let lastError = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await admin.messaging().send(message);
    } catch (error) {
      lastError = error;
      if (attempt < attempts) {
        await sleep(attempt * 1000);
      }
    }
  }
  throw lastError;
}

/**
 * One-shot wait:
 * When a user explicitly taps "wait for call to end" for a friend whose
 * activity is onCall, a waiter document is created.
 *
 * When the target profile leaves activity=onCall, send an FCM push to all
 * waiters. A waiter is deleted only after Firebase accepts the push. Failed
 * deliveries stay in Firestore with diagnostics instead of disappearing.
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
      logger.info("Call ended with no waiters", {targetUid});
      return;
    }

    const jobs = waiters.docs.map(async (waiterDoc) => {
      const waiterUid = waiterDoc.id;
      const waiterData = waiterDoc.data() || {};
      const requestedName =
        String(waiterData.targetName || targetName).trim() || targetName;

      try {
        // v37 stores the exact token that was verified at button press time.
        // Keep the private-user lookup as a fallback for older installed builds.
        let token = waiterData.fcmToken;
        if (typeof token !== "string" || token.length === 0) {
          const privateUser = await database
            .collection("private_users")
            .doc(waiterUid)
            .get();
          token = privateUser.data()?.fcmToken;
        }

        if (typeof token !== "string" || token.length === 0) {
          logger.warn("No FCM token for call waiter", {
            waiterUid,
            targetUid,
          });
          await waiterDoc.ref.set(
            {
              deliveryStatus: "failed",
              deliveryError: "missing_fcm_token",
              lastDeliveryAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
            },
            {merge: true},
          );
          return;
        }

        const messageId = await sendWithRetry({
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

        logger.info("Call-end notification accepted by FCM", {
          waiterUid,
          targetUid,
          messageId,
        });

        // One request = one successful notification opportunity.
        await waiterDoc.ref.delete();
      } catch (error) {
        const errorText = error?.message || String(error);
        logger.error("Failed to notify call waiter", {
          waiterUid,
          targetUid,
          error: errorText,
          code: error?.code,
        });

        // Do not throw the user's request away on failure. Keeping diagnostics
        // makes the problem visible and allows a fresh tap/token to replace it.
        await waiterDoc.ref.set(
          {
            deliveryStatus: "failed",
            deliveryError: errorText.slice(0, 500),
            deliveryErrorCode: error?.code || null,
            lastDeliveryAttemptAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          {merge: true},
        ).catch(() => {});
      }
    });

    await Promise.all(jobs);
  },
);
