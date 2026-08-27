package com.mikron30.matzav

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.telephony.TelephonyManager

/**
 * Receives the protected Android PHONE_STATE broadcast even when the Flutter
 * activity/process is not already running. Because the receiver is declared in
 * AndroidManifest.xml, Android can start the app process for a cellular call
 * state change. Updating the native shared preference wakes
 * NativeStatusSyncProvider, which mirrors the status to Firestore and also
 * applies/restores the automatic Do-Not-Disturb availability state.
 *
 * We intentionally do not request/read the incoming phone number.
 */
class PhoneStateReceiver : BroadcastReceiver() {
    companion object {
        private const val PREFS = "matzav_automatic_status_v20"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_CALL_ENABLED = "call_enabled"
        private const val KEY_CALL_ACTIVE = "call_active"

        // Some Android/vendor audio stacks keep MODE_IN_CALL or
        // MODE_IN_COMMUNICATION for a few seconds after TelephonyManager already
        // reports IDLE. The in-app monitor combines phone + audio state, so a
        // stale audio mode could otherwise turn a finished cellular call back on.
        private const val CALL_END_CLEANUP_MS = 6_000L
        private const val CALL_END_RECHECK_MS = 400L
        private const val FIRESTORE_GRACE_MS = 1_200L
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return

        val appContext = context.applicationContext
        val prefs = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (
            !prefs.getBoolean(KEY_ENABLED, false) ||
            !prefs.getBoolean(KEY_CALL_ENABLED, false)
        ) {
            return
        }

        when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
            TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                if (!prefs.getBoolean(KEY_CALL_ACTIVE, false)) {
                    // commit() is deliberate: the value must be on disk before
                    // onReceive can finish, especially on a cold-started process.
                    prefs.edit().putBoolean(KEY_CALL_ACTIVE, true).commit()
                }
                keepProcessAliveForFirestore()
            }

            TelephonyManager.EXTRA_STATE_IDLE -> {
                // On dual-SIM devices one subscription may become IDLE while a
                // call on the other subscription is still active. Query the
                // aggregate device call state before clearing Matzav's status.
                val aggregateState = currentPhoneState(appContext)
                if (aggregateState == TelephonyManager.CALL_STATE_OFFHOOK) {
                    return
                }

                // IDLE is authoritative for the end of a cellular conversation.
                // Clear immediately, then keep clearing briefly until the vendor
                // AudioManager leaves its lingering call mode.
                if (prefs.getBoolean(KEY_CALL_ACTIVE, false)) {
                    prefs.edit().putBoolean(KEY_CALL_ACTIVE, false).commit()
                }
                cleanupAfterCellularCall(appContext, prefs)
            }

            // Ringing by itself is not yet an active conversation. If another
            // call is already active (call waiting), keep the current value.
            TelephonyManager.EXTRA_STATE_RINGING -> Unit
        }
    }

    private fun keepProcessAliveForFirestore() {
        val pendingResult = goAsync()
        Handler(Looper.getMainLooper()).postDelayed(
            { pendingResult.finish() },
            FIRESTORE_GRACE_MS,
        )
    }

    private fun cleanupAfterCellularCall(
        context: Context,
        prefs: SharedPreferences,
    ) {
        val pendingResult = goAsync()
        val handler = Handler(Looper.getMainLooper())
        val startedAt = SystemClock.elapsedRealtime()
        val audioManager =
            context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        lateinit var check: Runnable
        check = Runnable {
            // Stop cleanup immediately if another cellular call started.
            if (currentPhoneState(context) != TelephonyManager.CALL_STATE_IDLE) {
                pendingResult.finish()
                return@Runnable
            }

            // The foreground in-app poller can briefly write true again while
            // AudioManager is still unwinding. Keep the authoritative IDLE state.
            if (prefs.getBoolean(KEY_CALL_ACTIVE, false)) {
                prefs.edit().putBoolean(KEY_CALL_ACTIVE, false).commit()
            }

            val elapsed = SystemClock.elapsedRealtime() - startedAt
            val audioStillInCallMode = isCommunicationMode(audioManager.mode)

            if (!audioStillInCallMode || elapsed >= CALL_END_CLEANUP_MS) {
                // Leave a short bounded window for NativeStatusSyncProvider to
                // queue the Firestore restoration and trigger call-wait alerts.
                handler.postDelayed(
                    { pendingResult.finish() },
                    FIRESTORE_GRACE_MS,
                )
            } else {
                handler.postDelayed(check, CALL_END_RECHECK_MS)
            }
        }

        handler.post(check)
    }

    private fun currentPhoneState(context: Context): Int {
        return try {
            @Suppress("DEPRECATION")
            val manager = context.getSystemService(
                Context.TELEPHONY_SERVICE,
            ) as TelephonyManager
            manager.callState
        } catch (_: Exception) {
            TelephonyManager.CALL_STATE_IDLE
        }
    }

    private fun isCommunicationMode(mode: Int): Boolean {
        if (
            mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION
        ) {
            return true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return mode == AudioManager.MODE_CALL_REDIRECT ||
                mode == AudioManager.MODE_COMMUNICATION_REDIRECT
        }

        return false
    }
}

/**
 * Starts the native process after reboot/app replacement so Sleep API pending
 * intents are re-registered without requiring the user to open Flutter first.
 * Location/drive detection is not started from boot; Android foreground-location
 * restrictions are respected and that feature resumes through its own service.
 */
class AutomationBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                NativeSleepScheduler.reconcile(context.applicationContext)
            }
        }
    }
}
