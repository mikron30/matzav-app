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

async function notifyWaiters({
  database,
  collection,
  targetUid,
  targetName,
  type,
  body,
  logLabel,
}) {
  const waitersRef = database
    .collection(collection)
    .doc(targetUid)
    .collection("waiters");

  const waiters = await waitersRef.get();
  if (waiters.empty) {
    logger.info(`${logLabel} with no waiters`, {targetUid});
    return;
  }

  const jobs = waiters.docs.map(async (waiterDoc) => {
    const waiterUid = waiterDoc.id;
    const waiterData = waiterDoc.data() || {};
    const requestedName =
      String(waiterData.targetName || targetName).trim() || targetName;

    try {
      // Store the token at button-press time, while keeping the private-user
      // lookup as a fallback for older builds or refreshed waiter documents.
      let token = waiterData.fcmToken;
      if (typeof token !== "string" || token.length === 0) {
        const privateUser = await database
          .collection("private_users")
          .doc(waiterUid)
          .get();
        token = privateUser.data()?.fcmToken;
      }

      if (typeof token !== "string" || token.length === 0) {
        logger.warn(`No FCM token for ${logLabel} waiter`, {
          waiterUid,
          targetUid,
        });
        await waiterDoc.ref.set(
          {
            deliveryStatus: "failed",
            deliveryError: "missing_fcm_token",
            lastDeliveryAttemptAt:
              admin.firestore.FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
        return;
      }

      const messageId = await sendWithRetry({
        token,
        notification: {
          title: "Matzav",
          body: body(requestedName),
        },
        data: {
          type,
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

      logger.info(`${logLabel} notification accepted by FCM`, {
        waiterUid,
        targetUid,
        messageId,
      });

      // One request = one successful notification opportunity.
      await waiterDoc.ref.delete();
    } catch (error) {
      const errorText = error?.message || String(error);
      logger.error(`Failed to notify ${logLabel} waiter`, {
        waiterUid,
        targetUid,
        error: errorText,
        code: error?.code,
      });

      // Keep failed requests with diagnostics instead of silently losing them.
      await waiterDoc.ref.set(
        {
          deliveryStatus: "failed",
          deliveryError: errorText.slice(0, 500),
          deliveryErrorCode: error?.code || null,
          lastDeliveryAttemptAt:
            admin.firestore.FieldValue.serverTimestamp(),
        },
        {merge: true},
      ).catch(() => {});
    }
  });

  await Promise.all(jobs);
}

/**
 * One profile-update trigger serves both one-shot status notifications:
 *   1) onCall -> anything else: notify call-end waiters.
 *   2) anything except driving -> driving: notify driving-start waiters.
 */
exports.notifyCallWaiters = onDocumentUpdated(
  {
    document: "profiles/{targetUid}",
    maxInstances: 10,
  },
  async (event) => {
    const before = event.data?.before?.data() || {};
    const after = event.data?.after?.data() || {};

    const callEnded =
      before.activity === "onCall" && after.activity !== "onCall";
    const drivingStarted =
      before.activity !== "driving" && after.activity === "driving";

    if (!callEnded && !drivingStarted) {
      return;
    }

    const targetUid = event.params.targetUid;
    const targetName =
      String(after.displayName || before.displayName || "החבר").trim() ||
      "החבר";
    const database = firestoreDb();

    const jobs = [];

    if (callEnded) {
      jobs.push(
        notifyWaiters({
          database,
          collection: "call_waits",
          targetUid,
          targetName,
          type: "call_finished",
          body: (name) => `${name} סיים/ה את השיחה`,
          logLabel: "call-end",
        }),
      );
    }

    if (drivingStarted) {
      jobs.push(
        notifyWaiters({
          database,
          collection: "driving_waits",
          targetUid,
          targetName,
          type: "driving_started",
          body: (name) => `${name} התחיל/ה לנסוע`,
          logLabel: "driving-start",
        }),
      );
    }

    await Promise.all(jobs);
  },
);
