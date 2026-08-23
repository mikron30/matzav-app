package com.mikron30.matzav

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val PHONE_HINT_CHANNEL = "com.mikron30.matzav/phone_hint"
        private const val DIRECT_CALL_CHANNEL = "com.mikron30.matzav/direct_call"
        private const val PHONE_HINT_REQUEST_CODE = 43127
        private const val CALL_PERMISSION_REQUEST_CODE = 43128
    }

    private var pendingPhoneHintResult: MethodChannel.Result? = null
    private var pendingCallResult: MethodChannel.Result? = null
    private var pendingCallPhone: String? = null

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
                            result.error("INVALID_PHONE", "Phone number is empty.", null)
                        } else {
                            requestDirectCall(phone, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestDirectCall(phone: String, result: MethodChannel.Result) {
        if (pendingCallResult != null) {
            result.error("CALL_ACTIVE", "Another call request is already active.", null)
            return
        }

        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED
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
            result.error("PHONE_HINT_ACTIVE", "Phone number selection is already open.", null)
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
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
