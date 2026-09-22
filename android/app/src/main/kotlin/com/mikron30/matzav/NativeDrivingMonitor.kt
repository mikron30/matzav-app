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
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.Operation
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.workDataOf
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Registers native vehicle transitions independently of the Flutter UI/GPS. */
class NativeDrivingProvider : ContentProvider(), SharedPreferences.OnSharedPreferenceChangeListener {
    private var flutterPrefs: SharedPreferences? = null
    private var automaticPrefs: SharedPreferences? = null
    private var authListener: FirebaseAuth.AuthStateListener? = null

    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        flutterPrefs = appContext.getSharedPreferences(NativeDrivingMonitor.FLUTTER_PREFS, Context.MODE_PRIVATE)
            .also { it.registerOnSharedPreferenceChangeListener(this) }
        automaticPrefs = appContext.getSharedPreferences(NativeDrivingMonitor.AUTOMATIC_PREFS, Context.MODE_PRIVATE)
            .also { it.registerOnSharedPreferenceChangeListener(this) }

        // WorkManager's initializer runs after this provider. Defer until all
        // providers are initialized, and wait for restored Firebase credentials.
        Handler(Looper.getMainLooper()).post {
            authListener = FirebaseAuth.AuthStateListener {
                NativeDrivingMonitor.reconcile(appContext)
            }.also { FirebaseAuth.getInstance().addAuthStateListener(it) }
        }
        return true
    }

    override fun onSharedPreferenceChanged(sharedPreferences: SharedPreferences?, key: String?) {
        val appContext = context?.applicationContext ?: return
        if (sharedPreferences === flutterPrefs &&
            (key == NativeDrivingMonitor.FLUTTER_DRIVING_ENABLED_KEY ||
                key == NativeDrivingMonitor.FLUTTER_LEGACY_MASTER_KEY)) {
            NativeDrivingMonitor.reconcile(appContext)
        } else if (sharedPreferences === automaticPrefs && key in setOf(
                "enabled", "call_enabled", "call_active", "sleep_enabled", "sleep_active")) {
            NativeDrivingMonitor.scheduleStatusSync(appContext)
        }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?,
        selectionArgs: Array<out String>?): Int = 0
}

object NativeDrivingMonitor {
    const val FLUTTER_PREFS = "FlutterSharedPreferences"
    const val FLUTTER_DRIVING_ENABLED_KEY = "flutter.matzav_auto_driving_v31"
    const val FLUTTER_LEGACY_MASTER_KEY = "flutter.matzav_automation_enabled_v25"
    const val AUTOMATIC_PREFS = "matzav_automatic_status_v20"
    const val KEY_OWNER = "owner_uid"
    const val KEY_ACTIVE = "driving_active"
    const val KEY_REVISION = "revision"
    const val KEY_PENDING = "pending_sync"
    const val KEY_HAS_STATE = "has_transition"
    const val ACTION_TRANSITION = "com.mikron30.matzav.DRIVING_TRANSITION"
    private const val DRIVING_PREFS = "matzav_native_driving_v43"
    private const val REQUEST_CODE = 44220
    private const val LEGACY_REQUEST_CODE = 43220
    private var registered = false
    private var registering = false

    fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(DRIVING_PREFS, Context.MODE_PRIVATE)

    fun enabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        return prefs.getBoolean(FLUTTER_DRIVING_ENABLED_KEY,
            prefs.getBoolean(FLUTTER_LEGACY_MASTER_KEY, true))
    }

    fun hasPermission(context: Context): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
        context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED

    fun isDrivingActive(context: Context): Boolean {
        val owner = FirebaseAuth.getInstance().currentUser?.uid ?: return false
        return enabled(context) && hasPermission(context) &&
            owner == prefs(context).getString(KEY_OWNER, null) &&
            prefs(context).getBoolean(KEY_ACTIVE, false)
    }

    fun returnActivity(context: Context): String? {
        val owner = FirebaseAuth.getInstance().currentUser?.uid ?: return null
        val state = prefs(context)
        if (state.getString(KEY_OWNER, null) != owner || !state.getBoolean(KEY_HAS_STATE, false)) return null
        val previous = state.getString("previous_activity", null)
            ?: state.getString("last_non_driving", null)
        return previous?.takeIf { DrivingStatusPolicy.stable(it) }
    }

    /**
     * Clears a stale IN_VEHICLE state after Flutter has stronger GPS evidence
     * that the trip ended. The return activity is persisted before the native
     * EXIT revision, so the worker cannot later restore an older status.
     */
    @Synchronized
    fun forceInactive(context: Context, returnActivity: String?): Boolean {
        val appContext = context.applicationContext
        val owner = FirebaseAuth.getInstance().currentUser?.uid ?: return false
        val state = prefs(appContext)

        if (state.getString(KEY_OWNER, null) != owner) return false

        returnActivity
            ?.takeIf { DrivingStatusPolicy.stable(it) }
            ?.let { stableReturn ->
                check(
                    state.edit()
                        .putString("previous_activity", stableReturn)
                        .putString("last_non_driving", stableReturn)
                        .commit(),
                ) { "Could not persist the forced driving return activity" }
            }

        // Record a fresh EXIT revision even if KEY_ACTIVE is already false.
        // This also repairs a cloud profile that is still stuck on "driving".
        recordState(appContext, owner, false)
        scheduleStatusSync(appContext)
        return true
    }

    @Synchronized
    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val user = FirebaseAuth.getInstance().currentUser
        if (user == null) {
            removeUpdates(appContext)
            prefs(appContext).getString(KEY_OWNER, null)?.let {
                WorkManager.getInstance(appContext).cancelUniqueWork(workName(it))
            }
            return
        }

        val state = prefs(appContext)
        val oldOwner = state.getString(KEY_OWNER, null)
        if (oldOwner != user.uid) {
            if (oldOwner != null) WorkManager.getInstance(appContext).cancelUniqueWork(workName(oldOwner))
            // Never carry another account's trip or restoration status forward.
            state.edit().clear().putString(KEY_OWNER, user.uid).apply()
        }
        if (!enabled(appContext) || !hasPermission(appContext)) {
            stop(appContext)
            return
        }
        if (!registered && !registering) registerUpdates(appContext)
        if (state.getBoolean(KEY_PENDING, false)) scheduleStatusSync(appContext)
        rememberCurrentNonDriving(appContext, user.uid)
    }

    fun stop(context: Context) {
        removeUpdates(context)
        if (prefs(context).getBoolean(KEY_ACTIVE, false)) {
            val owner = prefs(context).getString(KEY_OWNER, null) ?: return
            recordState(context, owner, false)
        }
        scheduleStatusSync(context)
    }

    @Synchronized
    fun recordState(context: Context, owner: String, active: Boolean) {
        val state = prefs(context)
        val editor = state.edit()
        if (active && !state.getBoolean(KEY_ACTIVE, false)) editor.remove("previous_activity")
        check(editor
            .putString(KEY_OWNER, owner)
            .putBoolean(KEY_ACTIVE, active)
            .putBoolean(KEY_HAS_STATE, true)
            .putBoolean(KEY_PENDING, true)
            .putLong(KEY_REVISION, state.getLong(KEY_REVISION, 0L) + 1L)
            .commit()) { "Could not persist the driving transition" }
    }

    @Synchronized
    fun completeSync(context: Context, owner: String, revision: Long, returnActivity: String?) {
        val state = prefs(context)
        if (!DrivingStatusPolicy.isCurrentSnapshot(owner,
                FirebaseAuth.getInstance().currentUser?.uid, state.getString(KEY_OWNER, null),
                revision, state.getLong(KEY_REVISION, 0L))) return
        val editor = state.edit().putBoolean(KEY_PENDING, false)
        returnActivity?.let { editor.putString("previous_activity", it) }
        editor.commit()
    }

    fun scheduleStatusSync(context: Context): Operation? {
        val state = prefs(context)
        val owner = state.getString(KEY_OWNER, null) ?: return null
        if (!state.getBoolean(KEY_HAS_STATE, false)) return null
        state.edit().putBoolean(KEY_PENDING, true).apply()
        val builder = OneTimeWorkRequestBuilder<DrivingStatusWorker>()
            .setInputData(workDataOf(KEY_OWNER to owner))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        // Every worker reads the latest persisted state, so replacing an older
        // backed-off job is safe. REPLACE is important here: APPEND_OR_REPLACE
        // can leave a fresh ENTER/EXIT waiting behind an old Firestore/DNS retry
        // for a long time, even after connectivity has recovered.
        return WorkManager.getInstance(context).enqueueUniqueWork(
            workName(owner), ExistingWorkPolicy.REPLACE, builder.build())
    }

    fun callOrSleepActive(context: Context): Boolean {
        val prefs = context.getSharedPreferences(AUTOMATIC_PREFS, Context.MODE_PRIVATE)
        return prefs.getBoolean("enabled", false) && (
            (prefs.getBoolean("call_enabled", false) && prefs.getBoolean("call_active", false)) ||
            (prefs.getBoolean("sleep_enabled", false) && prefs.getBoolean("sleep_active", false)))
    }

    private fun workName(owner: String) = "matzav-driving-status-$owner"

    private fun rememberCurrentNonDriving(context: Context, owner: String) {
        FirebaseFirestore.getInstance().collection("profiles").document(owner).get()
            .addOnSuccessListener { snapshot ->
                val activity = snapshot.getString("activity")
                if (prefs(context).getString(KEY_OWNER, null) == owner &&
                    DrivingStatusPolicy.stable(activity)) {
                    prefs(context).edit().putString("last_non_driving", activity).apply()
                }
            }
    }

    private fun registerUpdates(context: Context) {
        registering = true
        val request = ActivityTransitionRequest(listOf(
            ActivityTransition.Builder().setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER).build(),
            ActivityTransition.Builder().setActivityType(DetectedActivity.IN_VEHICLE)
                .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT).build()))
        try {
            removeLegacyPendingIntent(context)
            ActivityRecognition.getClient(context)
                .requestActivityTransitionUpdates(request, transitionPendingIntent(context))
                .addOnSuccessListener {
                    registering = false
                    registered = true
                    if (!enabled(context) || !hasPermission(context) ||
                        FirebaseAuth.getInstance().currentUser == null) removeUpdates(context)
                }
                .addOnFailureListener { error ->
                    registering = false
                    registered = false
                    Log.w("MatzavDriving", "Vehicle transition registration failed", error)
                }
        } catch (error: Exception) {
            registering = false
            registered = false
            Log.w("MatzavDriving", "Vehicle transition registration failed", error)
        }
    }

    private fun removeUpdates(context: Context) {
        registered = false
        try {
            if (hasPermission(context)) {
                ActivityRecognition.getClient(context)
                    .removeActivityTransitionUpdates(transitionPendingIntent(context))
                    .addOnFailureListener { error -> Log.w("MatzavDriving", "Vehicle unregister failed", error) }
            }
            removeLegacyPendingIntent(context)
        } catch (error: Exception) {
            Log.w("MatzavDriving", "Vehicle unregister failed", error)
        }
    }

    private fun removeLegacyPendingIntent(context: Context) {
        val old = PendingIntent.getBroadcast(context, LEGACY_REQUEST_CODE,
            Intent(context, DrivingTransitionReceiver::class.java),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
        if (hasPermission(context)) {
            ActivityRecognition.getClient(context).removeActivityTransitionUpdates(old)
                .addOnCompleteListener { old.cancel() }
        } else old.cancel()
    }

    private fun transitionPendingIntent(context: Context): PendingIntent {
        // Play services must fill in ActivityTransitionResult extras. IMMUTABLE
        // discards them. Keep the mutable intent explicitly scoped to our receiver.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        return PendingIntent.getBroadcast(context, REQUEST_CODE,
            Intent(context, DrivingTransitionReceiver::class.java).setAction(ACTION_TRANSITION), flags)
    }
}

class DrivingTransitionReceiver : BroadcastReceiver() {
    companion object {
        private val executor = Executors.newSingleThreadExecutor()
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val transitionIntent = intent ?: return
        if (transitionIntent.action != NativeDrivingMonitor.ACTION_TRANSITION ||
            !ActivityTransitionResult.hasResult(transitionIntent)) return
        val result = ActivityTransitionResult.extractResult(transitionIntent) ?: return
        val event = result.transitionEvents.lastOrNull { it.activityType == DetectedActivity.IN_VEHICLE } ?: return
        val active = when (event.transitionType) {
            ActivityTransition.ACTIVITY_TRANSITION_ENTER -> true
            ActivityTransition.ACTIVITY_TRANSITION_EXIT -> false
            else -> return
        }
        val appContext = context.applicationContext
        if (!NativeDrivingMonitor.enabled(appContext) || !NativeDrivingMonitor.hasPermission(appContext)) return
        val pending = goAsync()
        executor.execute {
            try {
                val owner = FirebaseAuth.getInstance().currentUser?.uid
                if (owner != null) {
                    NativeDrivingMonitor.recordState(appContext, owner, active)
                    // Keep only durable enqueueing in the broadcast's short
                    // lifetime. Network I/O belongs to WorkManager, not goAsync.
                    NativeDrivingMonitor.scheduleStatusSync(appContext)?.result?.get(5, TimeUnit.SECONDS)
                }
            } catch (error: Exception) {
                Log.w("MatzavDriving", "Could not enqueue vehicle status; persisted state will retry on startup", error)
            } finally {
                pending.finish()
            }
        }
    }
}
