package com.mikron30.matzav

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.android.gms.tasks.Tasks
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.util.concurrent.TimeUnit

/**
 * Durable background reconciliation for native call/sleep overrides.
 *
 * WorkManager survives process death and retries after transient network errors.
 * After the higher-priority call/sleep state is settled, pending driving state
 * is resumed so an EXIT cannot remain deferred indefinitely.
 */
class NativeStatusSyncWorker(
    context: Context,
    parameters: WorkerParameters,
) : Worker(context, parameters) {
    companion object {
        private const val NATIVE_PREFS = "matzav_automatic_status_v20"
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val FLUTTER_PREVIOUS_ACTIVITY_KEY =
            "flutter.automatic_status_previous_activity_v1"
        private const val BUSY_PREVIOUS_AVAILABILITY =
            "busyAvailabilityPrevious"
        private const val WORK_PREFIX = "matzav-native-status-sync-"

        private const val KEY_SYNC_RESULT = "override_sync_result"
        private const val KEY_SYNC_AT = "override_sync_at"
        private const val KEY_SYNC_ERROR = "override_sync_error"
        private const val KEY_SYNC_DESIRED = "override_sync_desired"

        fun schedule(context: Context) {
            val appContext = context.applicationContext
            val user = FirebaseAuth.getInstance().currentUser ?: return
            val request = OneTimeWorkRequestBuilder<NativeStatusSyncWorker>()
                .setInputData(workDataOf("owner" to user.uid))
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .setBackoffCriteria(
                    BackoffPolicy.EXPONENTIAL,
                    10,
                    TimeUnit.SECONDS,
                )
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                request.setExpedited(
                    OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST,
                )
            }
            try {
                WorkManager.getInstance(appContext).enqueueUniqueWork(
                    WORK_PREFIX + user.uid,
                    ExistingWorkPolicy.REPLACE,
                    request.build(),
                )
            } catch (_: IllegalStateException) {
                // Can happen during ContentProvider startup before WorkManager's
                // own initializer has run. The provider posts another sync after
                // startup, so failing closed here avoids a launch crash.
            }
        }
    }

    override fun doWork(): Result {
        val owner = inputData.getString("owner") ?: return Result.success()
        val user = FirebaseAuth.getInstance().currentUser ?: return Result.retry()
        if (user.uid != owner) return Result.success()

        val prefs = applicationContext.getSharedPreferences(
            NATIVE_PREFS,
            Context.MODE_PRIVATE,
        )
        val desired = desiredOverride(prefs)
        recordResult(prefs, "running", desired)

        val flutterPrevious = applicationContext
            .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            .getString(FLUTTER_PREVIOUS_ACTIVITY_KEY, null)

        val ref = FirebaseFirestore.getInstance()
            .collection("profiles")
            .document(owner)

        return try {
            Tasks.await(
                FirebaseFirestore.getInstance().runTransaction { transaction ->
                    val snapshot = transaction.get(ref)
                    if (!snapshot.exists()) return@runTransaction false

                    val data = HashMap<String, Any>(snapshot.data ?: emptyMap())
                    val currentActivity = data["activity"] as? String ?: "home"
                    val nativeOverride = data["automaticNativeOverride"] as? String
                    val storedPrevious = data["automaticPreviousActivity"] as? String
                    val updates = hashMapOf<String, Any>()
                    var resultingActivity = currentActivity

                    if (desired != "none") {
                        if (nativeOverride.isNullOrEmpty() || nativeOverride == "none") {
                            val previous = when {
                                currentActivity != "onCall" &&
                                    currentActivity != "sleeping" -> currentActivity
                                !storedPrevious.isNullOrEmpty() -> storedPrevious
                                !flutterPrevious.isNullOrEmpty() -> flutterPrevious
                                else -> "home"
                            }
                            updates["automaticPreviousActivity"] = previous
                        }

                        resultingActivity = desired
                        updates["activity"] = desired
                        updates["automaticNativeOverride"] = desired
                        forceBusyAvailability(data, updates)
                    } else if (!nativeOverride.isNullOrEmpty() && nativeOverride != "none") {
                        var restore = storedPrevious ?: flutterPrevious ?: "home"

                        if (restore == "meeting") {
                            val endsAt = data["activityTimerEndsAt"] as? Timestamp
                            if (
                                endsAt != null &&
                                endsAt.toDate().time <= System.currentTimeMillis()
                            ) {
                                restore =
                                    data["activityTimerPrevious"] as? String ?: "home"
                                updates["activityTimerEndsAt"] = FieldValue.delete()
                                updates["activityTimerPrevious"] = FieldValue.delete()
                            }
                        }

                        resultingActivity = restore
                        updates["activity"] = restore
                        updates["automaticNativeOverride"] = FieldValue.delete()
                        updates["automaticPreviousActivity"] = FieldValue.delete()

                        if (isBusyActivity(restore)) {
                            forceBusyAvailability(data, updates)
                        } else {
                            restoreBusyAvailability(data, updates)
                        }
                    } else if (
                        (currentActivity == "sleeping" || currentActivity == "onCall") &&
                        !flutterPrevious.isNullOrEmpty()
                    ) {
                        resultingActivity = flutterPrevious
                        updates["activity"] = flutterPrevious
                        updates["automaticNativeOverride"] = FieldValue.delete()
                        updates["automaticPreviousActivity"] = FieldValue.delete()

                        if (isBusyActivity(flutterPrevious)) {
                            forceBusyAvailability(data, updates)
                        } else {
                            restoreBusyAvailability(data, updates)
                        }
                    } else {
                        if (isBusyActivity(resultingActivity)) {
                            forceBusyAvailability(data, updates)
                        } else {
                            restoreBusyAvailability(data, updates)
                        }
                    }

                    if (updates.isNotEmpty()) {
                        updates["updatedAt"] = FieldValue.serverTimestamp()
                        transaction.set(ref, updates, SetOptions.merge())
                    }
                    true
                },
                20,
                TimeUnit.SECONDS,
            )

            recordResult(prefs, "applied", desired)
            NativeDrivingMonitor.scheduleStatusSync(applicationContext)
            Result.success()
        } catch (error: Exception) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            recordResult(
                prefs,
                "error_retry",
                desired,
                error.message ?: error.javaClass.simpleName,
            )
            Result.retry()
        }
    }

    private fun desiredOverride(
        prefs: android.content.SharedPreferences,
    ): String {
        val enabled = prefs.getBoolean("enabled", false)
        val callEnabled = prefs.getBoolean("call_enabled", false)
        val sleepEnabled = prefs.getBoolean("sleep_enabled", false)
        return when {
            !enabled -> "none"
            callEnabled && prefs.getBoolean("call_active", false) -> "onCall"
            sleepEnabled && prefs.getBoolean("sleep_active", false) -> "sleeping"
            else -> "none"
        }
    }

    private fun isBusyActivity(activity: String): Boolean {
        return activity == "meeting" ||
            activity == "onCall" ||
            activity == "sleeping"
    }

    private fun forceBusyAvailability(
        data: Map<String, Any>,
        updates: HashMap<String, Any>,
    ) {
        val current = data["availability"] as? String ?: "canTalk"
        val previous = data[BUSY_PREVIOUS_AVAILABILITY] as? String

        if (previous.isNullOrEmpty()) {
            val hasTimer = data["availabilityTimerEndsAt"] != null
            val value = if (current == "doNotDisturb" && !hasTimer) {
                "canTalk"
            } else {
                current
            }
            updates[BUSY_PREVIOUS_AVAILABILITY] = value
        }

        if (current != "doNotDisturb") {
            updates["availability"] = "doNotDisturb"
        }
    }

    private fun restoreBusyAvailability(
        data: Map<String, Any>,
        updates: HashMap<String, Any>,
    ) {
        val previous = data[BUSY_PREVIOUS_AVAILABILITY] as? String ?: return
        var restore = previous

        if (restore == "doNotDisturb") {
            val end = data["availabilityTimerEndsAt"] as? Timestamp
            if (end != null && end.toDate().time <= System.currentTimeMillis()) {
                restore = data["availabilityTimerPrevious"] as? String ?: "canTalk"
                updates["availabilityTimerEndsAt"] = FieldValue.delete()
                updates["availabilityTimerPrevious"] = FieldValue.delete()
            }
        }

        updates["availability"] = restore
        updates[BUSY_PREVIOUS_AVAILABILITY] = FieldValue.delete()
    }

    private fun recordResult(
        prefs: android.content.SharedPreferences,
        result: String,
        desired: String,
        error: String? = null,
    ) {
        val editor = prefs.edit()
            .putString(KEY_SYNC_RESULT, result)
            .putString(KEY_SYNC_DESIRED, desired)
            .putLong(KEY_SYNC_AT, System.currentTimeMillis())

        if (error == null) {
            editor.remove(KEY_SYNC_ERROR)
        } else {
            editor.putString(KEY_SYNC_ERROR, error.take(400))
        }
        editor.apply()
    }
}
