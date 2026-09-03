package com.mikron30.matzav

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.SetOptions

/**
 * Background-safe driving detection.
 *
 * Flutter's GPS stream is useful while the Flutter engine is alive, but it is
 * not a reliable trigger after the app UI/process has been removed. Google's
 * Activity Recognition Transition API is specifically designed to deliver
 * IN_VEHICLE enter/exit transitions through a PendingIntent, which can wake a
 * manifest BroadcastReceiver even when the Flutter UI is not running.
 *
 * This does NOT request ACCESS_BACKGROUND_LOCATION.
 */
class NativeDrivingProvider : ContentProvider(),
    SharedPreferences.OnSharedPreferenceChangeListener {

    private var flutterPrefs: SharedPreferences? = null
    private var automaticPrefs: SharedPreferences? = null

    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false

        flutterPrefs = appContext.getSharedPreferences(
            NativeDrivingMonitor.FLUTTER_PREFS,
            Context.MODE_PRIVATE,
        ).also { it.registerOnSharedPreferenceChangeListener(this) }

        automaticPrefs = appContext.getSharedPreferences(
            NativeDrivingMonitor.AUTOMATIC_PREFS,
            Context.MODE_PRIVATE,
        ).also { it.registerOnSharedPreferenceChangeListener(this) }

        NativeDrivingMonitor.reconcile(appContext)
        return true
    }

    override fun onSharedPreferenceChanged(
        sharedPreferences: SharedPreferences?,
        key: String?,
    ) {
        val appContext = context?.applicationContext ?: return

        if (sharedPreferences === flutterPrefs) {
            if (
                key == NativeDrivingMonitor.FLUTTER_DRIVING_ENABLED_KEY ||
                key == NativeDrivingMonitor.FLUTTER_LEGACY_MASTER_KEY
            ) {
                NativeDrivingMonitor.reconcile(appContext)
            }
            return
        }

        if (sharedPreferences === automaticPrefs) {
            if (
                key == NativeDrivingMonitor.KEY_CALL_ENABLED ||
                key == NativeDrivingMonitor.KEY_CALL_ACTIVE ||
                key == NativeDrivingMonitor.KEY_SLEEP_ENABLED ||
                key == NativeDrivingMonitor.KEY_SLEEP_ACTIVE
            ) {
                // The call/sleep provider may write its own Firestore update at
                // the same time. Re-check twice so driving is applied/restored
                // after that higher-priority override settles.
                NativeDrivingMonitor.scheduleStatusSync(appContext)
            }
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

object NativeDrivingMonitor {
    const val FLUTTER_PREFS = "FlutterSharedPreferences"
    const val FLUTTER_DRIVING_ENABLED_KEY = "flutter.matzav_auto_driving_v31"
    const val FLUTTER_LEGACY_MASTER_KEY = "flutter.matzav_automation_enabled_v25"

    const val AUTOMATIC_PREFS = "matzav_automatic_status_v20"
    const val KEY_CALL_ENABLED = "call_enabled"
    const val KEY_SLEEP_ENABLED = "sleep_enabled"
    const val KEY_CALL_ACTIVE = "call_active"
    const val KEY_SLEEP_ACTIVE = "sleep_active"

    private const val DRIVING_PREFS = "matzav_native_driving_v43"
    private const val KEY_DRIVING_ACTIVE = "driving_active"
    private const val KEY_PREVIOUS_ACTIVITY = "previous_activity"
    private const val KEY_LAST_NON_DRIVING = "last_non_driving"
    private const val TRANSITION_REQUEST_CODE = 43220

    private val handler = Handler(Looper.getMainLooper())

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        if (!drivingEnabled(appContext)) {
            removeTransitionUpdates(appContext)
            setDrivingActive(appContext, false)
            return
        }

        if (!hasActivityRecognitionPermission(appContext)) {
            // The existing automatic-status permission flow normally grants
            // Physical Activity for Sleep API. If the user denied it, GPS while
            // Flutter is open remains the fallback, but closed-app transitions
            // cannot be delivered by Android.
            return
        }

        requestTransitionUpdates(appContext)
        rememberCurrentNonDriving(appContext)

        // Firebase Auth may still be restoring when content providers start.
        // A short retry gives us a reliable return status before the next trip.
        handler.postDelayed({ rememberCurrentNonDriving(appContext) }, 1500L)
    }

    fun onTransitionIntent(
        context: Context,
        intent: Intent,
        onComplete: () -> Unit,
    ) {
        val appContext = context.applicationContext
        if (!drivingEnabled(appContext)) {
            onComplete()
            return
        }
        if (!ActivityTransitionResult.hasResult(intent)) {
            onComplete()
            return
        }

        val result = ActivityTransitionResult.extractResult(intent)
        if (result == null) {
            onComplete()
            return
        }

        var finalActive: Boolean? = null
        for (event in result.transitionEvents) {
            if (event.activityType != DetectedActivity.IN_VEHICLE) continue
            when (event.transitionType) {
                ActivityTransition.ACTIVITY_TRANSITION_ENTER -> finalActive = true
                ActivityTransition.ACTIVITY_TRANSITION_EXIT -> finalActive = false
            }
        }

        if (finalActive == null) {
            onComplete()
            return
        }

        setDrivingActive(appContext, finalActive, onComplete)
    }

    fun scheduleStatusSync(context: Context) {
        val appContext = context.applicationContext
        handler.postDelayed({ syncVisibleStatus(appContext) }, 250L)
        handler.postDelayed({ syncVisibleStatus(appContext) }, 1200L)
    }

    private fun setDrivingActive(
        context: Context,
        active: Boolean,
        onComplete: (() -> Unit)? = null,
    ) {
        val prefs = drivingPrefs(context)
        val changed = prefs.getBoolean(KEY_DRIVING_ACTIVE, false) != active
        if (changed) {
            prefs.edit().putBoolean(KEY_DRIVING_ACTIVE, active).apply()
        }
        syncVisibleStatus(context, onComplete)
    }

    private fun syncVisibleStatus(
        context: Context,
        onComplete: (() -> Unit)? = null,
    ) {
        val appContext = context.applicationContext
        val active = drivingPrefs(appContext)
            .getBoolean(KEY_DRIVING_ACTIVE, false) && drivingEnabled(appContext)

        // Phone call and sleep are higher-priority temporary statuses.
        if (callOrSleepOverrideActive(appContext)) {
            onComplete?.invoke()
            return
        }

        val user = FirebaseAuth.getInstance().currentUser
        if (user == null) {
            onComplete?.invoke()
            return
        }

        val prefs = drivingPrefs(appContext)
        val profileRef = com.google.firebase.firestore.FirebaseFirestore.getInstance()
            .collection("profiles")
            .document(user.uid)

        if (active) {
            val previous = prefs.getString(KEY_PREVIOUS_ACTIVITY, null)
                ?: prefs.getString(KEY_LAST_NON_DRIVING, null)
                ?: "home"

            if (!prefs.contains(KEY_PREVIOUS_ACTIVITY)) {
                prefs.edit().putString(KEY_PREVIOUS_ACTIVITY, previous).apply()
            }

            profileRef.set(
                mapOf(
                    "activity" to "driving",
                    "updatedAt" to FieldValue.serverTimestamp(),
                    "nativeDrivingDetected" to true,
                ),
                SetOptions.merge(),
            ).addOnCompleteListener {
                onComplete?.invoke()
            }
            return
        }

        val restore = sanitizeReturnActivity(
            prefs.getString(KEY_PREVIOUS_ACTIVITY, null)
                ?: prefs.getString(KEY_LAST_NON_DRIVING, null)
                ?: "home",
        )

        // Read the cached/current profile before restoring so a manual status
        // selected after driving is not overwritten unnecessarily.
        profileRef.get().addOnCompleteListener { task ->
            val current = if (task.isSuccessful) {
                task.result?.data?.get("activity") as? String
            } else {
                null
            }

            if (current == "driving" || current == null) {
                profileRef.set(
                    mapOf(
                        "activity" to restore,
                        "updatedAt" to FieldValue.serverTimestamp(),
                        "nativeDrivingDetected" to FieldValue.delete(),
                    ),
                    SetOptions.merge(),
                ).addOnCompleteListener {
                    prefs.edit()
                        .remove(KEY_PREVIOUS_ACTIVITY)
                        .putString(KEY_LAST_NON_DRIVING, restore)
                        .apply()
                    onComplete?.invoke()
                }
            } else {
                if (isStableNonDriving(current)) {
                    prefs.edit()
                        .remove(KEY_PREVIOUS_ACTIVITY)
                        .putString(KEY_LAST_NON_DRIVING, current)
                        .apply()
                }
                onComplete?.invoke()
            }
        }
    }

    private fun rememberCurrentNonDriving(context: Context) {
        val user = FirebaseAuth.getInstance().currentUser ?: return
        val profileRef = com.google.firebase.firestore.FirebaseFirestore.getInstance()
            .collection("profiles")
            .document(user.uid)

        profileRef.get().addOnSuccessListener { snapshot ->
            val activity = snapshot.data?.get("activity") as? String ?: return@addOnSuccessListener
            if (isStableNonDriving(activity)) {
                drivingPrefs(context).edit()
                    .putString(KEY_LAST_NON_DRIVING, activity)
                    .apply()
            }
        }
    }

    private fun isStableNonDriving(activity: String): Boolean {
        return activity != "driving" &&
            activity != "onCall" &&
            activity != "sleeping"
    }

    private fun sanitizeReturnActivity(activity: String): String {
        return when (activity) {
            "driving", "onCall", "sleeping" -> "home"
            else -> activity
        }
    }

    private fun callOrSleepOverrideActive(context: Context): Boolean {
        val prefs = context.getSharedPreferences(AUTOMATIC_PREFS, Context.MODE_PRIVATE)
        val callActive = prefs.getBoolean(KEY_CALL_ENABLED, false) &&
            prefs.getBoolean(KEY_CALL_ACTIVE, false)
        val sleepActive = prefs.getBoolean(KEY_SLEEP_ENABLED, false) &&
            prefs.getBoolean(KEY_SLEEP_ACTIVE, false)
        return callActive || sleepActive
    }

    private fun drivingEnabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val legacy = prefs.getBoolean(FLUTTER_LEGACY_MASTER_KEY, true)
        return prefs.getBoolean(FLUTTER_DRIVING_ENABLED_KEY, legacy)
    }

    private fun requestTransitionUpdates(context: Context) {
        val transitions = listOf(
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                .build(),
            ActivityTransition.Builder()
                .setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                .build(),
        )
        val request = ActivityTransitionRequest(transitions)

        try {
            ActivityRecognition.getClient(context)
                .requestActivityTransitionUpdates(request, transitionPendingIntent(context))
        } catch (_: SecurityException) {
            // Permission was revoked after registration.
        } catch (_: Exception) {
            // GPS-based detection while Flutter is alive remains the fallback.
        }
    }

    private fun removeTransitionUpdates(context: Context) {
        if (!hasActivityRecognitionPermission(context)) return
        try {
            ActivityRecognition.getClient(context)
                .removeActivityTransitionUpdates(transitionPendingIntent(context))
        } catch (_: Exception) {
            // Nothing else to clean up.
        }
    }

    private fun transitionPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, DrivingTransitionReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            TRANSITION_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun hasActivityRecognitionPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true
        return context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun drivingPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(DRIVING_PREFS, Context.MODE_PRIVATE)
}

class DrivingTransitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val pending = goAsync()
        NativeDrivingMonitor.onTransitionIntent(
            context.applicationContext,
            intent,
        ) {
            pending.finish()
        }
    }
}
