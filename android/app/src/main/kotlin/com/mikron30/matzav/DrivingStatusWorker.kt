package com.mikron30.matzav

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.android.gms.tasks.Tasks
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.util.concurrent.TimeUnit

/** Publishes a durable native transition without needing a Flutter engine. */
class DrivingStatusWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    private data class SyncOutcome(val kind: String, val returnActivity: String? = null)

    override fun doWork(): Result {
        val owner = inputData.getString(NativeDrivingMonitor.KEY_OWNER) ?: return Result.success()
        val state = NativeDrivingMonitor.prefs(applicationContext)
        if (state.getString(NativeDrivingMonitor.KEY_OWNER, null) != owner) return Result.success()
        val user = FirebaseAuth.getInstance().currentUser ?: return Result.retry()
        if (user.uid != owner) return Result.success()
        val revision = state.getLong(NativeDrivingMonitor.KEY_REVISION, 0L)
        val fallback = state.getString("previous_activity", null)
            ?: state.getString("last_non_driving", "home") ?: "home"
        val ref = FirebaseFirestore.getInstance().collection("profiles").document(owner)

        try {
            val outcome = Tasks.await(FirebaseFirestore.getInstance().runTransaction { transaction ->
                val snapshot = transaction.get(ref)
                if (isStopped || !DrivingStatusPolicy.isCurrentSnapshot(owner,
                        FirebaseAuth.getInstance().currentUser?.uid,
                        state.getString(NativeDrivingMonitor.KEY_OWNER, null), revision,
                        state.getLong(NativeDrivingMonitor.KEY_REVISION, 0L))) {
                    return@runTransaction SyncOutcome("obsolete")
                }
                if (!snapshot.exists()) return@runTransaction SyncOutcome("missing")
                val data = HashMap<String, Any>(snapshot.data ?: emptyMap())
                for (key in listOf("activityTimerEndsAt", "availabilityTimerEndsAt")) {
                    (data[key] as? Timestamp)?.let { data[key] = it.toDate().time }
                }
                val overrideActive = NativeDrivingMonitor.callOrSleepActive(applicationContext)
                if (DrivingStatusPolicy.isDeferred(data, overrideActive)) return@runTransaction SyncOutcome("deferred")
                val active = NativeDrivingMonitor.isDrivingActive(applicationContext)
                val changes = DrivingStatusPolicy.updates(data, active, overrideActive, fallback, System.currentTimeMillis())
                if (changes.isNotEmpty()) {
                    val updates = hashMapOf<String, Any>()
                    for ((key, value) in changes) updates[key] = value ?: FieldValue.delete()
                    updates["updatedAt"] = FieldValue.serverTimestamp()
                    transaction.set(ref, updates, SetOptions.merge())
                }
                val returnActivity = if (active) {
                    changes["nativeDrivingPreviousActivity"] as? String
                        ?: data["nativeDrivingPreviousActivity"] as? String
                } else {
                    changes["activity"] as? String ?: data["activity"] as? String
                }
                SyncOutcome("applied", returnActivity?.takeIf { DrivingStatusPolicy.stable(it) })
            }, 20, TimeUnit.SECONDS)

            if (outcome.kind == "missing") return Result.retry()

            if (outcome.kind == "applied") {
                NativeDrivingMonitor.completeSync(applicationContext, owner, revision, outcome.returnActivity)
            }
            // Call/sleep completion schedules another sync after its own write.
            return Result.success()
        } catch (error: Exception) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            Log.w("MatzavDriving", "Vehicle status sync will retry", error)
            return Result.retry()
        }
    }
}
