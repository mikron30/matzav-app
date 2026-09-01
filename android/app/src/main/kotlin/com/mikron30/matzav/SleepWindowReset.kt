package com.mikron30.matzav

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import java.util.Calendar

/**
 * Safety net for the automatic sleep detector.
 *
 * The regular Sleep API / fallback logic is only allowed to classify sleep
 * between 22:00 and 11:00. Older builds could leave sleep_active=true after
 * 11:00 when the screen stayed off and no new Sleep API event arrived. This
 * scheduler guarantees a wake-boundary check at 11:00 every day, even while
 * the Flutter UI is not running.
 */
object SleepWindowReset {
    private const val PREFS = "matzav_automatic_status_v20"
    private const val KEY_SLEEP_ACTIVE = "sleep_active"
    private const val REQUEST_CODE = 43204

    fun reconcile(context: Context) {
        val appContext = context.applicationContext
        val now = Calendar.getInstance()
        val hour = now.get(Calendar.HOUR_OF_DAY)

        // Outside the supported sleep window (11:00-21:59), sleeping is never
        // a valid automatic status. Clear any stale value immediately.
        if (hour >= 11 && hour < 22) {
            clearSleep(appContext)
        }

        scheduleNextBoundary(appContext)
    }

    private fun clearSleep(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_SLEEP_ACTIVE, false)) return

        prefs.edit().putBoolean(KEY_SLEEP_ACTIVE, false).apply()
        // NativeStatusSyncProvider observes the same preference and mirrors the
        // restored status to Firestore. This also refreshes Flutter when it is
        // currently attached.
        AutomaticStatusMonitor.onSleepStateChanged(context)
    }

    private fun scheduleNextBoundary(context: Context) {
        val now = Calendar.getInstance()
        val next = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 11)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (!after(now)) add(Calendar.DAY_OF_YEAR, 1)
        }

        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            next.timeInMillis,
            pendingIntent(context),
        )
    }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, SleepWindowResetReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/** Starts the daily wake-boundary schedule whenever the app process starts. */
class SleepWindowResetProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        SleepWindowReset.reconcile(appContext)
        return true
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

/**
 * Receives the 11:00 alarm and also rebuilds it after reboot/app replacement.
 */
class SleepWindowResetReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        SleepWindowReset.reconcile(context.applicationContext)
    }
}
