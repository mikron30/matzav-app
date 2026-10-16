package com.mikron30.matzav

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.firebase.auth.FirebaseAuth

/**
 * Fail-safe for a missing IN_VEHICLE EXIT.
 *
 * Normal trips end from Activity Transition EXIT. This worker only clears a
 * trip that stayed active for eight hours without a newer accepted transition,
 * so a missed EXIT can never leave the public profile on "driving" forever.
 */
class DrivingExpiryWorker(
    context: Context,
    parameters: WorkerParameters,
) : Worker(context, parameters) {
    override fun doWork(): Result {
        val owner = inputData.getString(NativeDrivingMonitor.KEY_OWNER)
            ?: return Result.success()
        val user = FirebaseAuth.getInstance().currentUser ?: return Result.retry()
        if (user.uid != owner) return Result.success()

        val state = NativeDrivingMonitor.prefs(applicationContext)
        if (state.getString(NativeDrivingMonitor.KEY_OWNER, null) != owner ||
            !state.getBoolean(NativeDrivingMonitor.KEY_ACTIVE, false)) {
            return Result.success()
        }

        val since = state.getLong(
            NativeDrivingMonitor.KEY_ACTIVE_SINCE_WALL_MS,
            0L,
        )
        if (since <= 0L) return Result.success()

        val ageMs = System.currentTimeMillis() - since
        if (ageMs < NativeDrivingMonitor.MAX_ACTIVE_DURATION_MS) {
            return Result.retry()
        }

        state.edit()
            .putString(
                NativeDrivingMonitor.KEY_LAST_TRANSITION_DECISION,
                "expired_active_timeout",
            )
            .apply()

        NativeDrivingMonitor.recordState(
            applicationContext,
            owner,
            false,
        )
        NativeDrivingMonitor.scheduleStatusSync(applicationContext)
        return Result.success()
    }
}
