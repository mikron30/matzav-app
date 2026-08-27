package com.mikron30.matzav

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val PHONE_HINT_CHANNEL = "com.mikron30.matzav/phone_hint"
        private const val DIRECT_CALL_CHANNEL = "com.mikron30.matzav/direct_call"
        private const val AUTOMATIC_STATUS_CHANNEL =
            "com.mikron30.matzav/automatic_status"
        private const val PHONE_HINT_REQUEST_CODE = 43127
        private const val CALL_PERMISSION_REQUEST_CODE = 43128
        private const val AUTOMATIC_PERMISSION_REQUEST_CODE = 43129
    }

    private var pendingPhoneHintResult: MethodChannel.Result? = null
    private var pendingCallResult: MethodChannel.Result? = null
    private var pendingCallPhone: String? = null
    private var pendingAutomaticStatusResult: MethodChannel.Result? = null
    private var pendingAutomaticCallsEnabled = true
    private var pendingAutomaticSleepEnabled = true
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
                "startMonitoring" -> {
                    val callsEnabled =
                        call.argument<Boolean>("callsEnabled") ?: true
                    val sleepEnabled =
                        call.argument<Boolean>("sleepEnabled") ?: true
                    startAutomaticMonitoring(
                        callsEnabled,
                        sleepEnabled,
                        result,
                    )
                }
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

    private fun missingAutomaticPermissions(
        callsEnabled: Boolean,
        sleepEnabled: Boolean,
    ): Array<String> {
        val missing = mutableListOf<String>()

        if (
            callsEnabled &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.READ_PHONE_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            missing.add(Manifest.permission.READ_PHONE_STATE)
        }

        if (
            sleepEnabled &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            missing.add(Manifest.permission.ACTIVITY_RECOGNITION)
        }

        return missing.toTypedArray()
    }

    private fun startAutomaticMonitoring(
        callsEnabled: Boolean,
        sleepEnabled: Boolean,
        result: MethodChannel.Result,
    ) {
        if (!callsEnabled && !sleepEnabled) {
            AutomaticStatusMonitor.stop(applicationContext)
            result.success(null)
            return
        }

        val missing = missingAutomaticPermissions(callsEnabled, sleepEnabled)
        if (missing.isNotEmpty()) {
            if (pendingAutomaticStatusResult != null) {
                result.error(
                    "AUTOMATIC_PERMISSION_ACTIVE",
                    "Automatic-detection permission request is already active.",
                    null,
                )
                return
            }
            pendingAutomaticStatusResult = result
            pendingAutomaticCallsEnabled = callsEnabled
            pendingAutomaticSleepEnabled = sleepEnabled
            requestPermissions(missing, AUTOMATIC_PERMISSION_REQUEST_CODE)
            return
        }

        AutomaticStatusMonitor.start(
            applicationContext,
            automaticStatusChannel!!,
            callsEnabled,
            sleepEnabled,
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

        if (requestCode == AUTOMATIC_PERMISSION_REQUEST_CODE) {
            val result = pendingAutomaticStatusResult ?: return
            pendingAutomaticStatusResult = null

            // Automatic detection still starts when a permission is denied.
            // Calls fall back to AudioManager and sleep falls back to the
            // conservative idle rule when Activity Recognition is absent.
            AutomaticStatusMonitor.start(
                applicationContext,
                automaticStatusChannel!!,
                pendingAutomaticCallsEnabled,
                pendingAutomaticSleepEnabled,
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
 * Aggregates two independent call detectors:
 * 1. Android telephony state for regular cellular calls.
 * 2. AudioManager communication mode for VoIP/WhatsApp/etc.
 *
 * Sleep state is produced by NativeSleepScheduler using Google's Sleep API
 * with a conservative idle fallback. Each detector can be enabled separately.
 */
object AutomaticStatusMonitor {
    private const val PREFS = "matzav_automatic_status_v20"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_CALL_ENABLED = "call_enabled"
    private const val KEY_SLEEP_ENABLED = "sleep_enabled"
    private const val KEY_CALL_ACTIVE = "call_active"
    private const val KEY_SLEEP_ACTIVE = "sleep_active"
    private const val CALL_STATE_POLL_MS = 2000L

    private var channel: MethodChannel? = null
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

    fun start(
        context: Context,
        newChannel: MethodChannel,
        callsEnabled: Boolean,
        sleepEnabled: Boolean,
    ) {
        channel = newChannel
        val appContext = context.applicationContext
        val enabled = callsEnabled || sleepEnabled
        prefs(appContext).edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putBoolean(KEY_CALL_ENABLED, callsEnabled)
            .putBoolean(KEY_SLEEP_ENABLED, sleepEnabled)
            .apply()

        if (callsEnabled) {
            startAudioMonitoring(appContext)
            startPhoneCallMonitoring(appContext)
            updateCallStateFromAudio(appContext)
            updateCallStateFromPhone(appContext)
        } else {
            stopAudioMonitoring()
            stopPhoneCallMonitoring()
            prefs(appContext).edit().putBoolean(KEY_CALL_ACTIVE, false).apply()
        }

        if (!sleepEnabled) {
            prefs(appContext).edit().putBoolean(KEY_SLEEP_ACTIVE, false).apply()
        }
        NativeSleepScheduler.reconcile(appContext)
        emitCurrentOverride(appContext)
    }

    fun stop(context: Context) {
        val appContext = context.applicationContext
        prefs(appContext).edit()
            .putBoolean(KEY_ENABLED, false)
            .putBoolean(KEY_CALL_ENABLED, false)
            .putBoolean(KEY_SLEEP_ENABLED, false)
            .putBoolean(KEY_CALL_ACTIVE, false)
            .putBoolean(KEY_SLEEP_ACTIVE, false)
            .apply()

        stopAudioMonitoring()
        stopPhoneCallMonitoring()
        NativeSleepScheduler.reconcile(appContext)
        emitCurrentOverride(appContext)
    }

    fun currentOverride(context: Context): String {
        val prefs = prefs(context.applicationContext)
        return when {
            prefs.getBoolean(KEY_CALL_ENABLED, false) &&
                prefs.getBoolean(KEY_CALL_ACTIVE, false) -> "onCall"
            prefs.getBoolean(KEY_SLEEP_ENABLED, false) &&
                prefs.getBoolean(KEY_SLEEP_ACTIVE, false) -> "sleeping"
            else -> "none"
        }
    }

    fun onSleepStateChanged(context: Context) {
        emitCurrentOverride(context.applicationContext)
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
        if (manager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
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
        if (
            !prefs.getBoolean(KEY_ENABLED, false) ||
            !prefs.getBoolean(KEY_CALL_ENABLED, false)
        ) {
            if (prefs.getBoolean(KEY_CALL_ACTIVE, false)) {
                prefs.edit().putBoolean(KEY_CALL_ACTIVE, false).apply()
                emitCurrentOverride(context)
            }
            return
        }

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
