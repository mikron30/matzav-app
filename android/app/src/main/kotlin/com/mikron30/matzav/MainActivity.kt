package com.mikron30.matzav

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.mikron30.matzav/phone_hint"
        private const val PHONE_HINT_REQUEST_CODE = 43127
    }

    private var pendingPhoneHintResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPhoneNumberHint" -> requestPhoneNumberHint(result)
                    else -> result.notImplemented()
                }
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
