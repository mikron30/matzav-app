package com.mikron30.matzav

import android.Manifest
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import com.google.firebase.auth.FirebaseAuth
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Keeps a small diagnostic snapshot/log in FlutterSharedPreferences so Flutter
 * can export it later. This provider is initialized whenever Android starts the
 * app process, including for background receivers. No diagnostics are uploaded.
 */
class NativeDiagnosticsProvider : ContentProvider(),
    SharedPreferences.OnSharedPreferenceChangeListener {

    companion object {
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"
        private const val DRIVING_PREFS = "matzav_native_driving_v43"
        private const val AUTOMATIC_PREFS = "matzav_automatic_status_v20"
        private const val SNAPSHOT_KEY = "flutter.matzav_native_debug_snapshot_v47"
        private const val LOG_KEY = "flutter.matzav_native_debug_log_v47"
        private const val MAX_LOG_CHARS = 48_000
        private const val MAX_LOG_LINES = 220
    }

    private var drivingPrefs: SharedPreferences? = null
    private var automaticPrefs: SharedPreferences? = null
    private var flutterPrefs: SharedPreferences? = null

    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        flutterPrefs = appContext.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        drivingPrefs = appContext.getSharedPreferences(DRIVING_PREFS, Context.MODE_PRIVATE)
            .also { it.registerOnSharedPreferenceChangeListener(this) }
        automaticPrefs = appContext.getSharedPreferences(AUTOMATIC_PREFS, Context.MODE_PRIVATE)
            .also { it.registerOnSharedPreferenceChangeListener(this) }

        appendEvent(appContext, "process_start")
        writeSnapshot(appContext)
        return true
    }

    override fun onSharedPreferenceChanged(
        sharedPreferences: SharedPreferences?,
        key: String?,
    ) {
        val appContext = context?.applicationContext ?: return
        val source = when (sharedPreferences) {
            drivingPrefs -> "driving"
            automaticPrefs -> "automatic"
            else -> "unknown"
        }
        appendEvent(appContext, "$source:${key ?: "?"}")
        writeSnapshot(appContext)
    }

    private fun writeSnapshot(context: Context) {
        val drive = drivingPrefs ?: context.getSharedPreferences(DRIVING_PREFS, Context.MODE_PRIVATE)
        val auto = automaticPrefs ?: context.getSharedPreferences(AUTOMATIC_PREFS, Context.MODE_PRIVATE)
        val user = FirebaseAuth.getInstance().currentUser

        val snapshot = JSONObject().apply {
            put("time", isoNow())
            put("sdk", Build.VERSION.SDK_INT)
            put("uidSuffix", user?.uid?.let(::uidSuffix) ?: "none")
            put("physicalActivityPermission", hasPermission(context, Manifest.permission.ACTIVITY_RECOGNITION))
            put("fineLocationPermission", hasPermission(context, Manifest.permission.ACCESS_FINE_LOCATION))
            put("coarseLocationPermission", hasPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION))
            put("drivingFeatureEnabled", NativeDrivingMonitor.enabled(context))
            put("drivingActiveEffective", NativeDrivingMonitor.isDrivingActive(context))

            put("driving", JSONObject().apply {
                put("ownerSuffix", drive.getString("owner_uid", null)?.let(::uidSuffix) ?: "none")
                put("active", drive.getBoolean("driving_active", false))
                put("hasTransition", drive.getBoolean("has_transition", false))
                put("pendingSync", drive.getBoolean("pending_sync", false))
                put("revision", drive.getLong("revision", 0L))
                put("previousActivity", drive.getString("previous_activity", null) ?: "none")
                put("lastNonDriving", drive.getString("last_non_driving", null) ?: "none")
            })

            put("automatic", JSONObject().apply {
                put("enabled", auto.getBoolean("enabled", false))
                put("callEnabled", auto.getBoolean("call_enabled", false))
                put("callActive", auto.getBoolean("call_active", false))
                put("sleepEnabled", auto.getBoolean("sleep_enabled", false))
                put("sleepActive", auto.getBoolean("sleep_active", false))
                put("screenOffAt", auto.getLong("screen_off_at", 0L))
                put("sleepApiLastEventMs", auto.getLong("sleep_api_last_event_ms", 0L))
                put("sleepApiConfidence", auto.getInt("sleep_api_confidence", -1))
            })
        }

        flutterPrefs
            ?.edit()
            ?.putString(SNAPSHOT_KEY, snapshot.toString())
            ?.apply()
    }

    private fun appendEvent(context: Context, event: String) {
        val prefs = flutterPrefs
            ?: context.getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
        val drive = drivingPrefs
            ?: context.getSharedPreferences(DRIVING_PREFS, Context.MODE_PRIVATE)
        val auto = automaticPrefs
            ?: context.getSharedPreferences(AUTOMATIC_PREFS, Context.MODE_PRIVATE)

        val line = buildString {
            append(isoNow())
            append(" | ")
            append(event)
            append(" | driveActive=")
            append(drive.getBoolean("driving_active", false))
            append(" pending=")
            append(drive.getBoolean("pending_sync", false))
            append(" rev=")
            append(drive.getLong("revision", 0L))
            append(" prev=")
            append(drive.getString("previous_activity", null) ?: "-")
            append(" last=")
            append(drive.getString("last_non_driving", null) ?: "-")
            append(" | call=")
            append(auto.getBoolean("call_active", false))
            append(" sleep=")
            append(auto.getBoolean("sleep_active", false))
        }

        val old = prefs.getString(LOG_KEY, "").orEmpty()
        val lines = (if (old.isEmpty()) emptyList() else old.lines()).toMutableList()
        lines.add(line)
        while (lines.size > MAX_LOG_LINES) lines.removeAt(0)
        var joined = lines.joinToString("\n")
        if (joined.length > MAX_LOG_CHARS) {
            joined = joined.takeLast(MAX_LOG_CHARS)
            val firstNewline = joined.indexOf('\n')
            if (firstNewline >= 0) joined = joined.substring(firstNewline + 1)
        }
        prefs.edit().putString(LOG_KEY, joined).apply()
    }

    private fun hasPermission(context: Context, permission: String): Boolean {
        if (permission == Manifest.permission.ACTIVITY_RECOGNITION &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return true
        }
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun isoNow(): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formatter.timeZone = TimeZone.getTimeZone("UTC")
        return formatter.format(Date())
    }

    private fun uidSuffix(uid: String): String {
        return if (uid.length <= 6) uid else "...${uid.takeLast(6)}"
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
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
