package com.mikron30.matzav

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.IntentSender
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.telephony.TelephonyManager
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.max

class MainActivity : FlutterActivity() {
    companion object {
        private const val PHONE_HINT_CHANNEL = "com.mikron30.matzav/phone_hint"
        private const val DIRECT_CALL_CHANNEL = "com.mikron30.matzav/direct_call"
        private const val AUTOMATIC_STATUS_CHANNEL =
            "com.mikron30.matzav/automatic_status"
        private const val PHONE_HINT_REQUEST_CODE = 43127
        private const val CALL_PERMISSION_REQUEST_CODE = 43128
        private const val PHONE_STATE_PERMISSION_REQUEST_CODE = 43129
    }

    private var pendingPhoneHintResult: MethodChannel.Result? = null
    private var pendingCallResult: MethodChannel.Result? = null
    private var pendingCallPhone: String? = null
    private var pendingAutomaticStatusResult: MethodChannel.Result? = null
    private var automaticStatusChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PHONE_HINT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPhoneNumberHint" -> requestPhoneNumberHint(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DIRECT_CALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "callNumber" -> {
                        val phone = call.argument<String>("phone")?.trim().orEmpty()
                        if (phone.isEmpty()) {
                            result.error(
                                "INVALID_PHONE",
                                "Phone number is empty.",
                                null,
                            )
                        } else {
                            requestDirectCall(phone, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        automaticStatusChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUTOMATIC_STATUS_CHANNEL,
        )
        automaticStatusChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "startMonitoring" -> startAutomaticMonitoring(result)
                "stopMonitoring" -> {
                    AutomaticStatusMonitor.stop(applicationContext)
                    result.success(null)
                }
                "getCurrentOverride" -> {
                    result.success(
                        AutomaticStatusMonitor.currentOverride(applicationContext),
                    )
                }
                else -> result.notImplemented()
            }
        }

        AutomaticStatusMonitor.attachChannel(automaticStatusChannel!!)
    }

    private fun startAutomaticMonitoring(result: MethodChannel.Result) {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.READ_PHONE_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingAutomaticStatusResult != null) {
                result.error(
                    "PHONE_STATE_PERMISSION_ACTIVE",
                    "Phone-state permission request is already active.",
                    null,
                )
                return
            }
            pendingAutomaticStatusResult = result
            requestPermissions(
                arrayOf(Manifest.permission.READ_PHONE_STATE),
                PHONE_STATE_PERMISSION_REQUEST_CODE,
            )
            return
        }

        AutomaticStatusMonitor.start(
            applicationContext,
            automaticStatusChannel!!,
        )
        result.success(null)
    }

    private fun requestDirectCall(phone: String, result: MethodChannel.Result) {
        if (pendingCallResult != null) {
            result.error(
                "CALL_ACTIVE",
                "Another call request is already active.",
                null,
            )
            return
        }

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.CALL_PHONE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingCallResult = result
            pendingCallPhone = phone
            requestPermissions(
                arrayOf(Manifest.permission.CALL_PHONE),
                CALL_PERMISSION_REQUEST_CODE,
            )
            return
        }

        startDirectCall(phone, result)
    }

    private fun startDirectCall(phone: String, result: MethodChannel.Result) {
        try {
            val intent = Intent(Intent.ACTION_CALL).apply {
                data = Uri.fromParts("tel", phone, null)
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("CALL_FAILED", error.message, null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == PHONE_STATE_PERMISSION_REQUEST_CODE) {
            val result = pendingAutomaticStatusResult ?: return
            pendingAutomaticStatusResult = null

            // Automatic detection still starts if permission was denied;
            // AudioManager remains as the VoIP/fallback detector. When Phone
            // permission is granted, the aggregate Android call-state poller is
            // enabled as well.
            AutomaticStatusMonitor.start(
                applicationContext,
                automaticStatusChannel!!,
            )
            result.success(null)
            return
        }

        if (requestCode != CALL_PERMISSION_REQUEST_CODE) return

        val result = pendingCallResult ?: return
        val phone = pendingCallPhone
        pendingCallResult = null
        pendingCallPhone = null

        if (
            grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED &&
            phone != null
        ) {
            startDirectCall(phone, result)
        } else {
            result.error(
                "CALL_PERMISSION_DENIED",
                "Phone call permission was not granted.",
                null,
            )
        }
    }

    private fun requestPhoneNumberHint(result: MethodChannel.Result) {
        if (pendingPhoneHintResult != null) {
            result.error(
                "PHONE_HINT_ACTIVE",
                "Phone number selection is already open.",
                null,
            )
            return
        }

        pendingPhoneHintResult = result
        val request = GetPhoneNumberHintIntentRequest.builder().build()

        Identity.getSignInClient(this)
            .getPhoneNumberHintIntent(request)
            .addOnSuccessListener { pendingIntent ->
                try {
                    startIntentSenderForResult(
                        pendingIntent.intentSender,
                        PHONE_HINT_REQUEST_CODE,
                        null,
                        0,
                        0,
                        0,
                    )
                } catch (e: IntentSender.SendIntentException) {
                    completePhoneHintWithError(e)
                }
            }
            .addOnFailureListener { error ->
                completePhoneHintWithError(error)
            }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != PHONE_HINT_REQUEST_CODE) return

        val result = pendingPhoneHintResult ?: return
        pendingPhoneHintResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(null)
            return
        }

        try {
            val phoneNumber =
                Identity.getSignInClient(this).getPhoneNumberFromIntent(data)
            result.success(phoneNumber)
        } catch (e: Exception) {
            result.error("PHONE_HINT_FAILED", e.message, null)
        }
    }

    private fun completePhoneHintWithError(error: Exception) {
        val result = pendingPhoneHintResult ?: return
        pendingPhoneHintResult = null
        result.error("PHONE_HINT_FAILED", error.message, null)
    }
}

/**
 * Keeps two automatic temporary states:
 * 1. "onCall" when Android reports an active phone/ConnectionService call OR
 *    AudioManager reports a phone/VoIP communication mode.
 * 2. "sleeping" after 22:00 when the device has stayed non-interactive for
 *    at least 10 minutes. Sleeping ends on the first USER_PRESENT unlock.
 *
 * The monitor does not read phone numbers, call logs, call audio, or message
 * content. READ_PHONE_STATE is used only for the aggregate call-state value.
 * The location foreground service from Flutter keeps the app process alive
 * while Automatic Detection is enabled.
 */
object AutomaticStatusMonitor {
    private const val PREFS = "matzav_automatic_status_v20"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_CALL_ACTIVE = "call_active"
    private const val KEY_SLEEP_ACTIVE = "sleep_active"
    private const val KEY_SCREEN_OFF_AT = "screen_off_at"
    private const val KEY_COMPLETED_NIGHT = "completed_night"

    private const val SLEEP_DELAY_MS = 10L * 60L * 1000L
    private const val SLEEP_ALARM_REQUEST_CODE = 43201
    private const val CALL_STATE_POLL_MS = 2000L

    private var channel: MethodChannel? = null
    private var screenReceiver: BroadcastReceiver? = null
    private var audioManager: AudioManager? = null
    private var modeListener: AudioManager.OnModeChangedListener? = null
    private var telephonyManager: TelephonyManager? = null
    private var phoneStatePoll: Runnable? = null
    private val handler = Handler(Looper.getMainLooper())
    private var legacyAudioPoll: Runnable? = null
    private var audioCallActive = false
    private var phoneCallActive = false

    fun attachChannel(newChannel: MethodChannel) {
        channel = newChannel
    }

    fun start(context: Context, newChannel: MethodChannel) {
        channel = newChannel
        val appContext = context.applicationContext
        val prefs = prefs(appContext)
        prefs.edit().putBoolean(KEY_ENABLED, true).apply()

        if (screenReceiver == null) {
            screenReceiver = object : BroadcastReceiver() {
                override fun onReceive(receiverContext: Context, intent: Intent) {
                    when (intent.action) {
                        Intent.ACTION_SCREEN_OFF ->
                            handleScreenOff(receiverContext.applicationContext)
                        Intent.ACTION_USER_PRESENT ->
                            handleUserPresent(receiverContext.applicationContext)
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

        startAudioMonitoring(appContext)
        startPhoneCallMonitoring(appContext)

        val powerManager =
            appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            if (prefs.getBoolean(KEY_SLEEP_ACTIVE, false)) {
                prefs.edit()
                    .putBoolean(KEY_SLEEP_ACTIVE, false)
                    .putString(KEY_COMPLETED_NIGHT, nightKey(System.currentTimeMillis()))
                    .apply()
            }
            prefs.edit().remove(KEY_SCREEN_OFF_AT).apply()
            cancelSleepAlarm(appContext)
            emitCurrentOverride(appContext)
        } else {
            if (!prefs.contains(KEY_SCREEN_OFF_AT)) {
                prefs.edit()
                    .putLong(KEY_SCREEN_OFF_AT, System.currentTimeMillis())
                    .apply()
            }
            scheduleSleepCheck(appContext)
        }

        updateCallStateFromAudio(appContext)
        updateCallStateFromPhone(appContext)
    }

    fun stop(context: Context) {
        val appContext = context.applicationContext
        prefs(appContext).edit()
            .putBoolean(KEY_ENABLED, false)
            .putBoolean(KEY_CALL_ACTIVE, false)
            .putBoolean(KEY_SLEEP_ACTIVE, false)
            .remove(KEY_SCREEN_OFF_AT)
            .apply()

        screenReceiver?.let {
            try {
                appContext.unregisterReceiver(it)
            } catch (_: Exception) {
                // Already unregistered.
            }
        }
        screenReceiver = null

        stopAudioMonitoring()
        stopPhoneCallMonitoring()
        cancelSleepAlarm(appContext)
        emitCurrentOverride(appContext)
    }

    fun currentOverride(context: Context): String {
        val prefs = prefs(context.applicationContext)
        return when {
            prefs.getBoolean(KEY_CALL_ACTIVE, false) -> "onCall"
            prefs.getBoolean(KEY_SLEEP_ACTIVE, false) -> "sleeping"
            else -> "none"
        }
    }

    fun handleSleepAlarm(context: Context) {
        val appContext = context.applicationContext
        val prefs = prefs(appContext)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        val now = System.currentTimeMillis()
        if (!nightWindowEligible(now)) {
            scheduleSleepCheck(appContext)
            return
        }

        val powerManager =
            appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            prefs.edit().remove(KEY_SCREEN_OFF_AT).apply()
            return
        }

        val completed = prefs.getString(KEY_COMPLETED_NIGHT, null)
        if (completed == nightKey(now)) return

        val screenOffAt = prefs.getLong(KEY_SCREEN_OFF_AT, 0L)
        if (screenOffAt <= 0L) {
            prefs.edit().putLong(KEY_SCREEN_OFF_AT, now).apply()
            scheduleSleepCheck(appContext)
            return
        }

        val elapsed = now - screenOffAt
        if (elapsed < SLEEP_DELAY_MS) {
            scheduleSleepCheck(appContext)
            return
        }

        prefs.edit().putBoolean(KEY_SLEEP_ACTIVE, true).apply()
        emitCurrentOverride(appContext)
    }

    private fun handleScreenOff(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        prefs.edit()
            .putLong(KEY_SCREEN_OFF_AT, System.currentTimeMillis())
            .apply()
        scheduleSleepCheck(context)
    }

    private fun handleUserPresent(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        val wasSleeping = prefs.getBoolean(KEY_SLEEP_ACTIVE, false)
        val editor = prefs.edit()
            .remove(KEY_SCREEN_OFF_AT)
            .putBoolean(KEY_SLEEP_ACTIVE, false)

        if (wasSleeping) {
            editor.putString(
                KEY_COMPLETED_NIGHT,
                nightKey(System.currentTimeMillis()),
            )
        }
        editor.apply()

        cancelSleepAlarm(context)
        emitCurrentOverride(context)
    }

    private fun startAudioMonitoring(context: Context) {
        if (audioManager != null) return

        val manager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = manager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val listener = AudioManager.OnModeChangedListener { mode ->
                setAudioCallActive(context, isCommunicationMode(mode))
            }
            modeListener = listener
            manager.addOnModeChangedListener(context.mainExecutor, listener)
        } else {
            val poll = object : Runnable {
                override fun run() {
                    val currentManager = audioManager ?: return
                    setAudioCallActive(
                        context,
                        isCommunicationMode(currentManager.mode),
                    )
                    handler.postDelayed(this, 5000L)
                }
            }
            legacyAudioPoll = poll
            handler.post(poll)
        }
    }

    private fun stopAudioMonitoring() {
        val manager = audioManager
        if (
            manager != null &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        ) {
            modeListener?.let {
                try {
                    manager.removeOnModeChangedListener(it)
                } catch (_: Exception) {
                    // Ignore platform cleanup failures.
                }
            }
        }

        legacyAudioPoll?.let { handler.removeCallbacks(it) }
        legacyAudioPoll = null
        modeListener = null
        audioManager = null
        audioCallActive = false
    }

    private fun startPhoneCallMonitoring(context: Context) {
        if (telephonyManager != null) return

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            phoneCallActive = false
            updateCombinedCallState(context)
            return
        }

        val manager =
            context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        telephonyManager = manager

        val poll = object : Runnable {
            override fun run() {
                val currentManager = telephonyManager ?: return
                val active = try {
                    @Suppress("DEPRECATION")
                    currentManager.callState == TelephonyManager.CALL_STATE_OFFHOOK
                } catch (_: SecurityException) {
                    false
                } catch (_: UnsupportedOperationException) {
                    false
                }

                setPhoneCallActive(context, active)
                handler.postDelayed(this, CALL_STATE_POLL_MS)
            }
        }
        phoneStatePoll = poll
        handler.post(poll)
    }

    private fun stopPhoneCallMonitoring() {
        phoneStatePoll?.let { handler.removeCallbacks(it) }
        phoneStatePoll = null
        telephonyManager = null
        phoneCallActive = false
    }

    private fun updateCallStateFromAudio(context: Context) {
        val manager =
            audioManager ?: context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        setAudioCallActive(context, isCommunicationMode(manager.mode))
    }

    private fun updateCallStateFromPhone(context: Context) {
        val manager = telephonyManager ?: return
        val active = try {
            @Suppress("DEPRECATION")
            manager.callState == TelephonyManager.CALL_STATE_OFFHOOK
        } catch (_: SecurityException) {
            false
        } catch (_: UnsupportedOperationException) {
            false
        }
        setPhoneCallActive(context, active)
    }

    private fun setAudioCallActive(context: Context, active: Boolean) {
        if (audioCallActive == active) return
        audioCallActive = active
        updateCombinedCallState(context)
    }

    private fun setPhoneCallActive(context: Context, active: Boolean) {
        if (phoneCallActive == active) return
        phoneCallActive = active
        updateCombinedCallState(context)
    }

    private fun updateCombinedCallState(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        val active = audioCallActive || phoneCallActive
        if (prefs.getBoolean(KEY_CALL_ACTIVE, false) == active) return

        prefs.edit().putBoolean(KEY_CALL_ACTIVE, active).apply()
        emitCurrentOverride(context)
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

    private fun scheduleSleepCheck(context: Context) {
        val prefs = prefs(context)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        val now = System.currentTimeMillis()
        val screenOffAt = prefs.getLong(KEY_SCREEN_OFF_AT, now)
        val idleTarget = screenOffAt + SLEEP_DELAY_MS
        val triggerAt = max(idleTarget, nextNightStartIfNeeded(now))

        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerAt,
            sleepPendingIntent(context),
        )
    }

    private fun nextNightStartIfNeeded(now: Long): Long {
        val calendar = Calendar.getInstance().apply {
            timeInMillis = now
        }
        val hour = calendar.get(Calendar.HOUR_OF_DAY)

        // 22:00 through 11:59 belongs to the nighttime window.
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

    private fun nightKey(now: Long): String {
        val calendar = Calendar.getInstance().apply {
            timeInMillis = now
        }
        if (calendar.get(Calendar.HOUR_OF_DAY) < 22) {
            calendar.add(Calendar.DAY_OF_YEAR, -1)
        }
        return SimpleDateFormat(
            "yyyy-MM-dd",
            Locale.US,
        ).format(Date(calendar.timeInMillis))
    }

    private fun cancelSleepAlarm(context: Context) {
        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        alarmManager.cancel(sleepPendingIntent(context))
    }

    private fun sleepPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, SleepCheckReceiver::class.java)
        return PendingIntent.getBroadcast(
            context,
            SLEEP_ALARM_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun emitCurrentOverride(context: Context) {
        val value = currentOverride(context)
        Handler(Looper.getMainLooper()).post {
            channel?.invokeMethod(
                "statusOverrideChanged",
                mapOf("activity" to value),
            )
        }
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

class SleepCheckReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        AutomaticStatusMonitor.handleSleepAlarm(context.applicationContext)
    }
}
