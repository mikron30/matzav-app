package com.mikron30.matzav

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.util.Calendar
import kotlin.math.max

/**
 * Mirrors Android automatic overrides directly to Firestore and keeps nighttime
 * sleep detection alive even if Flutter's method channel is not attached.
 */
class NativeStatusSyncProvider : ContentProvider(),
    SharedPreferences.OnSharedPreferenceChangeListener {

    companion object {
        private const val NATIVE_PREFS = "matzav_automatic_status_v20"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_CALL_ACTIVE = "call_active"
        private const val KEY_SLEEP_ACTIVE = "sleep_active"

        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val FLUTTER_PREVIOUS_ACTIVITY_KEY =
            "flutter.automatic_status_previous_activity_v1"
    }

    private var nativePrefs: SharedPreferences? = null
    private var screenReceiver: BroadcastReceiver? = null

    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        nativePrefs = appContext.getSharedPreferences(
            NATIVE_PREFS,
            Context.MODE_PRIVATE,
        ).also {
            it.registerOnSharedPreferenceChangeListener(this)
        }

        registerScreenReceiver(appContext)
        NativeSleepScheduler.reconcile(appContext)
        syncStatus(appContext)
        return true
    }

    private fun registerScreenReceiver(appContext: Context) {
        if (screenReceiver != null) return

        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_OFF ->
                        NativeSleepScheduler.onScreenOff(context.applicationContext)
                    Intent.ACTION_USER_PRESENT ->
                        NativeSleepScheduler.onUserPresent(context.applicationContext)
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            appContext.registerReceiver(
                screenReceiver,
                filter,
                Context.RECEIVER_EXPORTED,
            )
        } else {
            @Suppress("DEPRECATION")
            appContext.registerReceiver(screenReceiver, filter)
        }
    }

    override fun onSharedPreferenceChanged(
        sharedPreferences: SharedPreferences?,
        key: String?,
    ) {
        val appContext = context?.applicationContext ?: return

        if (key == KEY_ENABLED) {
            NativeSleepScheduler.reconcile(appContext)
        }

        if (
            key == KEY_ENABLED ||
            key == KEY_CALL_ACTIVE ||
            key == KEY_SLEEP_ACTIVE
        ) {
            syncStatus(appContext)
        }
    }

    private fun syncStatus(appContext: Context) {
        val prefs = nativePrefs ?: appContext.getSharedPreferences(
            NATIVE_PREFS,
            Context.MODE_PRIVATE,
        )

        val enabled = prefs.getBoolean(KEY_ENABLED, false)
        val desired = when {
            !enabled -> "none"
            prefs.getBoolean(KEY_CALL_ACTIVE, false) -> "onCall"
            prefs.getBoolean(KEY_SLEEP_ACTIVE, false) -> "sleeping"
            else -> "none"
        }

        val user = FirebaseAuth.getInstance().currentUser ?: return
        val profileRef = FirebaseFirestore.getInstance()
            .collection("profiles")
            .document(user.uid)

        val flutterPrevious = appContext
            .getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
            .getString(FLUTTER_PREVIOUS_ACTIVITY_KEY, null)

        profileRef.get().addOnCompleteListener { task ->
            val snapshot = if (task.isSuccessful) task.result else null
            val currentActivity = snapshot?.getString("activity") ?: "home"
            val nativeOverride = snapshot?.getString("automaticNativeOverride")
            val storedPrevious = snapshot?.getString("automaticPreviousActivity")

            val updates = hashMapOf<String, Any>()

            if (desired != "none") {
                if (nativeOverride.isNullOrEmpty() || nativeOverride == "none") {
                    val previous = when {
                        currentActivity != "onCall" && currentActivity != "sleeping" ->
                            currentActivity
                        !storedPrevious.isNullOrEmpty() -> storedPrevious
                        !flutterPrevious.isNullOrEmpty() -> flutterPrevious
                        else -> "home"
                    }
                    updates["automaticPreviousActivity"] = previous
                }

                updates["activity"] = desired
                updates["automaticNativeOverride"] = desired
            } else if (!nativeOverride.isNullOrEmpty() && nativeOverride != "none") {
                var restore = storedPrevious
                    ?: flutterPrevious
                    ?: "home"

                // Match StatusTimerService: do not restore an expired meeting.
                if (restore == "meeting") {
                    val endsAt = snapshot?.getTimestamp("activityTimerEndsAt")
                    if (
                        endsAt != null &&
                        endsAt.toDate().time <= System.currentTimeMillis()
                    ) {
                        restore = snapshot.getString("activityTimerPrevious") ?: "home"
                        updates["activityTimerEndsAt"] = FieldValue.delete()
                        updates["activityTimerPrevious"] = FieldValue.delete()
                    }
                }

                updates["activity"] = restore
                updates["automaticNativeOverride"] = FieldValue.delete()
                updates["automaticPreviousActivity"] = FieldValue.delete()
            } else if (
                (currentActivity == "sleeping" || currentActivity == "onCall") &&
                !flutterPrevious.isNullOrEmpty()
            ) {
                // Recovery path for a temporary status left by an older build.
                updates["activity"] = flutterPrevious
                updates["automaticNativeOverride"] = FieldValue.delete()
                updates["automaticPreviousActivity"] = FieldValue.delete()
            } else {
                return@addOnCompleteListener
            }

            updates["updatedAt"] = FieldValue.serverTimestamp()
            profileRef.set(updates, SetOptions.merge())
        }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}

/**
 * Independent native sleep scheduler.
 *
 * It uses the same preference keys as AutomaticStatusMonitor, so either side
 * can drive the state. Unlike the old one-night guard, every new screen-off
 * period can become sleeping again after 10 minutes.
 */
object NativeSleepScheduler {
    private const val PREFS = "matzav_automatic_status_v20"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_SLEEP_ACTIVE = "sleep_active"
    private const val KEY_SCREEN_OFF_AT = "screen_off_at"
    private const val KEY_COMPLETED_NIGHT = "completed_night"

    private const val SLEEP_DELAY_MS = 10L * 60L * 1000L
    private const val ALARM_REQUEST_CODE = 43202

    private val handler = Handler(Looper.getMainLooper())
    private var pendingRunnable: Runnable? = null

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)

        if (!prefs.getBoolean(KEY_ENABLED, false)) {
            cancel(appContext)
            return
        }

        val powerManager =
            appContext.getSystemService(Context.POWER_SERVICE) as PowerManager

        if (powerManager.isInteractive) {
            prefs.edit()
                .remove(KEY_SCREEN_OFF_AT)
                .remove(KEY_COMPLETED_NIGHT)
                .putBoolean(KEY_SLEEP_ACTIVE, false)
                .apply()
            cancel(appContext)
            return
        }

        if (!prefs.contains(KEY_SCREEN_OFF_AT)) {
            prefs.edit()
                .putLong(KEY_SCREEN_OFF_AT, System.currentTimeMillis())
                .remove(KEY_COMPLETED_NIGHT)
                .apply()
        }

        evaluateOrSchedule(appContext)
    }

    fun onScreenOff(context: Context) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        prefs.edit()
            .putLong(KEY_SCREEN_OFF_AT, System.currentTimeMillis())
            .remove(KEY_COMPLETED_NIGHT)
            .apply()

        schedule(appContext)
    }

    fun onUserPresent(context: Context) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        // Unlock means awake now, but another screen-off period later tonight
        // is allowed to become sleeping again after 10 minutes.
        prefs.edit()
            .remove(KEY_SCREEN_OFF_AT)
            .remove(KEY_COMPLETED_NIGHT)
            .putBoolean(KEY_SLEEP_ACTIVE, false)
            .apply()

        cancel(appContext)
    }

    fun handleAlarm(context: Context) {
        evaluateOrSchedule(context.applicationContext)
    }

    private fun evaluateOrSchedule(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) {
            cancel(context)
            return
        }

        val powerManager =
            context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            prefs.edit()
                .remove(KEY_SCREEN_OFF_AT)
                .putBoolean(KEY_SLEEP_ACTIVE, false)
                .apply()
            cancel(context)
            return
        }

        val now = System.currentTimeMillis()
        var screenOffAt = prefs.getLong(KEY_SCREEN_OFF_AT, 0L)
        if (screenOffAt <= 0L) {
            screenOffAt = now
            prefs.edit().putLong(KEY_SCREEN_OFF_AT, screenOffAt).apply()
        }

        if (!nightWindowEligible(now)) {
            schedule(context)
            return
        }

        if (now - screenOffAt >= SLEEP_DELAY_MS) {
            prefs.edit()
                .remove(KEY_COMPLETED_NIGHT)
                .putBoolean(KEY_SLEEP_ACTIVE, true)
                .apply()
            cancel(context)
            return
        }

        schedule(context)
    }

    private fun schedule(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        val now = System.currentTimeMillis()
        val screenOffAt = prefs.getLong(KEY_SCREEN_OFF_AT, now)
        val idleTarget = screenOffAt + SLEEP_DELAY_MS
        val triggerAt = max(idleTarget, nextNightStartIfNeeded(now))
        val delay = max(0L, triggerAt - now)

        pendingRunnable?.let(handler::removeCallbacks)
        pendingRunnable = Runnable {
            evaluateOrSchedule(context.applicationContext)
        }.also {
            handler.postDelayed(it, delay)
        }

        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerAt,
            pendingIntent(context),
        )
    }

    private fun cancel(context: Context) {
        pendingRunnable?.let(handler::removeCallbacks)
        pendingRunnable = null

        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(pendingIntent(context))
    }

    private fun nextNightStartIfNeeded(now: Long): Long {
        val calendar = Calendar.getInstance().apply {
            timeInMillis = now
        }
        val hour = calendar.get(Calendar.HOUR_OF_DAY)

        if (hour >= 22 || hour < 12) return now

        calendar.set(Calendar.HOUR_OF_DAY, 22)
        calendar.set(Calendar.MINUTE, 0)
        calendar.set(Calendar.SECOND, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        return calendar.timeInMillis
    }

    private fun nightWindowEligible(now: Long): Boolean {
        val calendar = Calendar.getInstance().apply {
            timeInMillis = now
        }
        val hour = calendar.get(Calendar.HOUR_OF_DAY)
        return hour >= 22 || hour < 12
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, NativeSleepCheckReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

class NativeSleepCheckReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        NativeSleepScheduler.handleAlarm(context.applicationContext)
    }
}
