package com.mikron30.matzav

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.database.Cursor
import android.net.Uri
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions

/**
 * Mirrors Android automatic overrides directly to Firestore.
 *
 * The sleep alarm is delivered to native Android even when Flutter's method
 * channel is detached. Listening to the same SharedPreferences used by
 * AutomaticStatusMonitor lets the status still become "sleeping" (and later
 * return to the previous activity) without depending on a live Flutter UI.
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

    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        nativePrefs = appContext.getSharedPreferences(
            NATIVE_PREFS,
            Context.MODE_PRIVATE,
        ).also {
            it.registerOnSharedPreferenceChangeListener(this)
        }

        // Also reconcile persisted state after Android recreates the process.
        syncStatus(appContext)
        return true
    }

    override fun onSharedPreferenceChanged(
        sharedPreferences: SharedPreferences?,
        key: String?,
    ) {
        if (
            key != KEY_ENABLED &&
            key != KEY_CALL_ACTIVE &&
            key != KEY_SLEEP_ACTIVE
        ) {
            return
        }
        context?.applicationContext?.let(::syncStatus)
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
