package com.mikron30.matzav

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.SleepClassifyEvent
import com.google.android.gms.location.SleepSegmentRequest
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.util.Calendar
import kotlin.math.max

/**
 * Mirrors native automatic call/sleep overrides directly to Firestore, even
 * when Flutter is not attached. It also owns the native sleep subscription.
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

        private const val BUSY_PREVIOUS_AVAILABILITY =
            "busyAvailabilityPrevious"
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
                // Migration from a build that forced DND without remembering
                // the previous value. The UI normally creates a timer for a
                // manually chosen DND, so no timer means canTalk is safest.
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
            val data = snapshot?.data ?: emptyMap<String, Any>()
            val currentActivity = data["activity"] as? String ?: "home"
            val nativeOverride = data["automaticNativeOverride"] as? String
            val storedPrevious = data["automaticPreviousActivity"] as? String

            val updates = hashMapOf<String, Any>()
            var resultingActivity = currentActivity

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

                resultingActivity = desired
                updates["activity"] = desired
                updates["automaticNativeOverride"] = desired
                forceBusyAvailability(data, updates)
            } else if (!nativeOverride.isNullOrEmpty() && nativeOverride != "none") {
                var restore = storedPrevious
                    ?: flutterPrevious
                    ?: "home"

                if (restore == "meeting") {
                    val endsAt = data["activityTimerEndsAt"] as? Timestamp
                    if (
                        endsAt != null &&
                        endsAt.toDate().time <= System.currentTimeMillis()
                    ) {
                        restore = data["activityTimerPrevious"] as? String ?: "home"
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
                // Keep availability consistent even if activity was changed by
                // Flutter while the native process was alive.
                if (isBusyActivity(resultingActivity)) {
                    forceBusyAvailability(data, updates)
                } else {
                    restoreBusyAvailability(data, updates)
                }
            }

            if (updates.isEmpty()) return@addOnCompleteListener
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
 * Sleep detection built around Google's Sleep API. Classification events use
 * device motion and ambient light in addition to inactivity. A conservative
 * screen-off fallback is retained for devices where the Sleep API is missing
 * or temporarily silent.
 */
object NativeSleepScheduler {
    private const val PREFS = "matzav_automatic_status_v20"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_SLEEP_ACTIVE = "sleep_active"
    private const val KEY_SCREEN_OFF_AT = "screen_off_at"
    private const val KEY_SLEEP_API_LAST_EVENT_MS = "sleep_api_last_event_ms"
    private const val KEY_SLEEP_API_CONFIDENCE = "sleep_api_confidence"

    private const val NIGHT_CONFIDENCE = 80
    private const val MORNING_CONFIDENCE = 92
    private const val WAKE_CONFIDENCE = 35
    private const val API_FRESH_MS = 30L * 60L * 1000L
    private const val FALLBACK_NIGHT_MS = 45L * 60L * 1000L
    private const val FALLBACK_MORNING_MS = 90L * 60L * 1000L
    private const val ALARM_REQUEST_CODE = 43202
    private const val SLEEP_UPDATE_REQUEST_CODE = 43203

    private val handler = Handler(Looper.getMainLooper())
    private var pendingRunnable: Runnable? = null

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)

        if (!prefs.getBoolean(KEY_ENABLED, false)) {
            removeSleepApiUpdates(appContext)
            setSleepActive(appContext, false)
            prefs.edit()
                .remove(KEY_SCREEN_OFF_AT)
                .remove(KEY_SLEEP_API_LAST_EVENT_MS)
                .remove(KEY_SLEEP_API_CONFIDENCE)
                .apply()
            cancelFallback(appContext)
            return
        }

        requestSleepApiUpdates(appContext)

        val powerManager =
            appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            setSleepActive(appContext, false)
            prefs.edit().remove(KEY_SCREEN_OFF_AT).apply()
            cancelFallback(appContext)
        } else {
            if (!prefs.contains(KEY_SCREEN_OFF_AT)) {
                prefs.edit()
                    .putLong(KEY_SCREEN_OFF_AT, System.currentTimeMillis())
                    .apply()
            }
            evaluateFallback(appContext)
        }
    }

    fun onScreenOff(context: Context) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        prefs.edit()
            .putLong(KEY_SCREEN_OFF_AT, System.currentTimeMillis())
            .apply()
        scheduleFallback(appContext)
    }

    fun onUserPresent(context: Context) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        prefs.edit()
            .remove(KEY_SCREEN_OFF_AT)
            .remove(KEY_SLEEP_API_LAST_EVENT_MS)
            .remove(KEY_SLEEP_API_CONFIDENCE)
            .apply()
        setSleepActive(appContext, false)
        cancelFallback(appContext)
    }

    fun onSleepIntent(context: Context, intent: Intent) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return
        if (!SleepClassifyEvent.hasEvents(intent)) return

        val latest = SleepClassifyEvent.extractEvents(intent)
            .maxByOrNull { it.timestampMillis }
            ?: return

        val now = System.currentTimeMillis()
        prefs.edit()
            .putLong(KEY_SLEEP_API_LAST_EVENT_MS, latest.timestampMillis)
            .putInt(KEY_SLEEP_API_CONFIDENCE, latest.confidence)
            .apply()

        val powerManager =
            appContext.getSystemService(Context.POWER_SERVICE) as PowerManager

        if (!sleepWindowEligible(now) || powerManager.isInteractive) {
            setSleepActive(appContext, false)
            scheduleFallback(appContext)
            return
        }

        val threshold = confidenceThreshold(now)
        when {
            latest.confidence >= threshold -> setSleepActive(appContext, true)
            latest.confidence <= WAKE_CONFIDENCE -> setSleepActive(appContext, false)
        }

        scheduleFallback(appContext)
    }

    fun handleFallbackAlarm(context: Context) {
        evaluateFallback(context.applicationContext)
    }

    private fun requestSleepApiUpdates(context: Context) {
        if (!hasActivityRecognitionPermission(context)) return

        try {
            ActivityRecognition.getClient(context)
                .requestSleepSegmentUpdates(
                    sleepUpdatePendingIntent(context),
                    SleepSegmentRequest.getDefaultSleepSegmentRequest(),
                )
        } catch (_: Exception) {
            // Conservative idle fallback remains active.
        }
    }

    private fun removeSleepApiUpdates(context: Context) {
        if (!hasActivityRecognitionPermission(context)) return
        try {
            ActivityRecognition.getClient(context)
                .removeSleepSegmentUpdates(sleepUpdatePendingIntent(context))
        } catch (_: Exception) {
            // Nothing else to clean up.
        }
    }

    private fun hasActivityRecognitionPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun evaluateFallback(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) {
            cancelFallback(context)
            return
        }

        val powerManager =
            context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            setSleepActive(context, false)
            prefs.edit().remove(KEY_SCREEN_OFF_AT).apply()
            cancelFallback(context)
            return
        }

        val now = System.currentTimeMillis()
        if (!sleepWindowEligible(now)) {
            setSleepActive(context, false)
            scheduleFallback(context)
            return
        }

        var screenOffAt = prefs.getLong(KEY_SCREEN_OFF_AT, 0L)
        if (screenOffAt <= 0L) {
            screenOffAt = now
            prefs.edit().putLong(KEY_SCREEN_OFF_AT, screenOffAt).apply()
        }

        val lastApiEvent = prefs.getLong(KEY_SLEEP_API_LAST_EVENT_MS, 0L)
        val apiIsFresh = lastApiEvent > 0L && now - lastApiEvent < API_FRESH_MS

        // If Google's model has reported recently, trust it and do not let
        // screen inactivity overrule a fresh classification.
        if (apiIsFresh) {
            scheduleFallback(context)
            return
        }

        val requiredIdle = fallbackDelay(now)
        if (now - screenOffAt >= requiredIdle) {
            setSleepActive(context, true)
            cancelFallback(context)
            return
        }

        scheduleFallback(context)
    }

    private fun scheduleFallback(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        val now = System.currentTimeMillis()
        var screenOffAt = prefs.getLong(KEY_SCREEN_OFF_AT, 0L)
        if (screenOffAt <= 0L) {
            screenOffAt = now
            prefs.edit().putLong(KEY_SCREEN_OFF_AT, screenOffAt).apply()
        }

        val idleTarget = screenOffAt + fallbackDelay(now)
        val lastApiEvent = prefs.getLong(KEY_SLEEP_API_LAST_EVENT_MS, 0L)
        val apiFreshUntil = if (lastApiEvent > 0L) {
            lastApiEvent + API_FRESH_MS
        } else {
            0L
        }
        val triggerAt = max(
            max(idleTarget, nextNightStartIfNeeded(now)),
            apiFreshUntil,
        )
        val safeTriggerAt = max(triggerAt, now + 60_000L)
        val delay = max(0L, safeTriggerAt - now)

        pendingRunnable?.let(handler::removeCallbacks)
        pendingRunnable = Runnable {
            evaluateFallback(context.applicationContext)
        }.also {
            handler.postDelayed(it, delay)
        }

        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            safeTriggerAt,
            fallbackPendingIntent(context),
        )
    }

    private fun cancelFallback(context: Context) {
        pendingRunnable?.let(handler::removeCallbacks)
        pendingRunnable = null

        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(fallbackPendingIntent(context))
    }

    private fun setSleepActive(context: Context, active: Boolean) {
        val prefs = prefs(context)
        if (prefs.getBoolean(KEY_SLEEP_ACTIVE, false) == active) return
        prefs.edit().putBoolean(KEY_SLEEP_ACTIVE, active).apply()
        AutomaticStatusMonitor.onSleepStateChanged(context)
    }

    private fun confidenceThreshold(now: Long): Int {
        val hour = Calendar.getInstance().apply { timeInMillis = now }
            .get(Calendar.HOUR_OF_DAY)
        return if (hour >= 8 && hour < 11) {
            MORNING_CONFIDENCE
        } else {
            NIGHT_CONFIDENCE
        }
    }

    private fun fallbackDelay(now: Long): Long {
        val hour = Calendar.getInstance().apply { timeInMillis = now }
            .get(Calendar.HOUR_OF_DAY)
        return if (hour >= 8 && hour < 11) {
            FALLBACK_MORNING_MS
        } else {
            FALLBACK_NIGHT_MS
        }
    }

    private fun sleepWindowEligible(now: Long): Boolean {
        val calendar = Calendar.getInstance().apply { timeInMillis = now }
        val hour = calendar.get(Calendar.HOUR_OF_DAY)
        return hour >= 22 || hour < 11
    }

    private fun nextNightStartIfNeeded(now: Long): Long {
        val calendar = Calendar.getInstance().apply { timeInMillis = now }
        val hour = calendar.get(Calendar.HOUR_OF_DAY)

        if (hour >= 22 || hour < 11) return now

        calendar.set(Calendar.HOUR_OF_DAY, 22)
        calendar.set(Calendar.MINUTE, 0)
        calendar.set(Calendar.SECOND, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        return calendar.timeInMillis
    }

    private fun fallbackPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, NativeSleepCheckReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            ALARM_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun sleepUpdatePendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, SleepUpdateReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            SLEEP_UPDATE_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

class NativeSleepCheckReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        NativeSleepScheduler.handleFallbackAlarm(context.applicationContext)
    }
}

class SleepUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        NativeSleepScheduler.onSleepIntent(context.applicationContext, intent)
    }
}
