package com.mikron30.matzav

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
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
        private const val ASYNC_GRACE_MS = 7_500L
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

        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        val active = when (state) {
            TelephonyManager.EXTRA_STATE_OFFHOOK -> true
            TelephonyManager.EXTRA_STATE_IDLE -> false
            // Ringing by itself is not yet an active conversation. If another
            // call is already active (call waiting), leave the current value as-is.
            TelephonyManager.EXTRA_STATE_RINGING -> return
            else -> return
        }

        if (prefs.getBoolean(KEY_CALL_ACTIVE, false) == active) return

        // commit() is deliberate: the value must be on disk before onReceive
        // can finish, so a cold-started process cannot lose the transition.
        prefs.edit().putBoolean(KEY_CALL_ACTIVE, active).commit()

        // NativeStatusSyncProvider performs an asynchronous Firestore read/write
        // after the preference changes. Keep the broadcast process important for
        // a short bounded window so that write can be queued even when the UI is
        // completely closed.
        val pendingResult = goAsync()
        Handler(Looper.getMainLooper()).postDelayed(
            { pendingResult.finish() },
            ASYNC_GRACE_MS,
        )
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
