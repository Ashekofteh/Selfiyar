package ir.ac.uk.bahonar_nut

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.auth.api.phone.SmsRetriever
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Status
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var notifier: ReminderNotifier? = null
    private var alarms: AlarmScheduler? = null
    private var isSmsReceiverRegistered = false
    private var isConsentInFlight = false

    private val smsVerificationReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // A broadcast receiver runs on the main looper. Any uncaught throwable here
            // (BadParcelableException, ClassCastException, ...) kills the process, so the
            // whole body is defensive: whatever happens, the consent session is reset and
            // the receiver is removed instead of crashing the app.
            try {
                if (SmsRetriever.SMS_RETRIEVED_ACTION != intent.action) return
                val extras = intent.extras
                if (extras == null) {
                    isConsentInFlight = false
                    unregisterSmsReceiver()
                    return
                }
                // Unmarshalling parcelables needs the framework/app ClassLoader. Without it
                // Android throws BadParcelableException on the main thread when the extras
                // were written by Play Services.
                extras.classLoader = Status::class.java.classLoader

                val smsRetrieverStatus =
                    extras.safeParcelable<Status>(SmsRetriever.EXTRA_STATUS)
                when (smsRetrieverStatus?.statusCode) {
                    CommonStatusCodes.SUCCESS -> {
                        val consentIntent =
                            extras.safeParcelable<Intent>(SmsRetriever.EXTRA_CONSENT_INTENT)
                        if (consentIntent != null && !isFinishing && !isDestroyed) {
                            // Unregister receiver immediately to prevent concurrent or duplicate broadcasts
                            // (e.g. from prior consent requests or multiple Play Services listeners)
                            // from re-triggering onReceive or attempting duplicate dialog launches.
                            unregisterSmsReceiver()
                            try {
                                val uriGrants = Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                consentIntent.flags = consentIntent.flags and uriGrants.inv()
                                startActivityForResult(consentIntent, SMS_CONSENT_REQUEST)
                            } catch (_: Throwable) {
                                isConsentInFlight = false
                            }
                        } else {
                            isConsentInFlight = false
                            unregisterSmsReceiver()
                        }
                    }
                    CommonStatusCodes.TIMEOUT -> {
                        isConsentInFlight = false
                        unregisterSmsReceiver()
                    }
                    else -> {
                        isConsentInFlight = false
                        unregisterSmsReceiver()
                    }
                }
            } catch (_: Throwable) {
                isConsentInFlight = false
                unregisterSmsReceiver()
            }
        }
    }

    /**
     * Reads a parcelable from the bundle without ever throwing.
     *
     * Wrong ClassLoaders and unexpected types surface as BadParcelableException or
     * ClassCastException, both of which must not escape a broadcast receiver.
     */
    private inline fun <reified T : android.os.Parcelable> Bundle.safeParcelable(
        key: String,
    ): T? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelable(key, T::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelable(key)
        }
    } catch (_: Throwable) {
        null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val notifier = ReminderNotifier(this)
        val alarms = AlarmScheduler(this)
        this.notifier = notifier
        this.alarms = alarms

        val initialDeepLink = intent.getStringExtra(ReminderNotifier.EXTRA_DEEP_LINK)
        if (initialDeepLink != null) {
            pendingInitialDeepLink = initialDeepLink
            intent.removeExtra(ReminderNotifier.EXTRA_DEEP_LINK)
        }

        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).also { methodChannel ->
            methodChannel.setMethodCallHandler(
                PlatformChannel(this, notifier, alarms),
            )
        }

        PlatformChannelMessenger.attach(channel!!, notifier, alarms)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A notification tap arrives here when the activity is already running.
        val deepLink = intent.getStringExtra(ReminderNotifier.EXTRA_DEEP_LINK)
        if (deepLink != null) {
            channel?.invokeMethod("deepLink", deepLink)
        }
    }

    fun registerSmsReceiver(): Boolean {
        if (isSmsReceiverRegistered) return true
        val intentFilter = IntentFilter(SmsRetriever.SMS_RETRIEVED_ACTION)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ContextCompat.registerReceiver(
                    this,
                    smsVerificationReceiver,
                    intentFilter,
                    SmsRetriever.SEND_PERMISSION,
                    null,
                    ContextCompat.RECEIVER_EXPORTED,
                )
            } else {
                ContextCompat.registerReceiver(
                    this,
                    smsVerificationReceiver,
                    intentFilter,
                    SmsRetriever.SEND_PERMISSION,
                    null,
                    0,
                )
            }
            isSmsReceiverRegistered = true
            true
        } catch (_: Throwable) {
            isSmsReceiverRegistered = false
            false
        }
    }

    fun unregisterSmsReceiver() {
        if (!isSmsReceiverRegistered) return
        try {
            unregisterReceiver(smsVerificationReceiver)
        } catch (_: Throwable) {}
        isSmsReceiverRegistered = false
    }

    fun stopSmsUserConsent() {
        isConsentInFlight = false
        unregisterSmsReceiver()
    }

    fun startSmsUserConsent(rawResult: MethodChannel.Result) {
        // The Dart side may call this concurrently (e.g. screen rebuilt while a previous
        // request is in flight) and Play Services may answer late. Replying twice to a
        // MethodChannel.Result throws `IllegalStateException: Reply already submitted`
        // on the main thread and crashes the app, so every reply goes through a claim.
        val result = SingleReplyResult(rawResult)
        if (isConsentInFlight) {
            // An SMS User Consent dialog or listener is already active in Play Services;
            // ensure the receiver is listening and reuse the existing session.
            if (!registerSmsReceiver()) {
                result.error("SMS_RETRIEVER_ERROR", "Failed to register SMS receiver", null)
                return
            }
            result.success(true)
            return
        }
        isConsentInFlight = true
        if (!registerSmsReceiver()) {
            isConsentInFlight = false
            result.error("SMS_RETRIEVER_ERROR", "Failed to register SMS receiver", null)
            return
        }
        try {
            SmsRetriever.getClient(this).startSmsUserConsent(null)
                .addOnSuccessListener {
                    result.success(true)
                }
                .addOnFailureListener { e ->
                    isConsentInFlight = false
                    unregisterSmsReceiver()
                    result.error("SMS_RETRIEVER_ERROR", e.message, null)
                }
        } catch (e: Exception) {
            isConsentInFlight = false
            unregisterSmsReceiver()
            result.error("SMS_RETRIEVER_ERROR", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SMS_CONSENT_REQUEST) {
            isConsentInFlight = false
            unregisterSmsReceiver()
            try {
                if (resultCode == Activity.RESULT_OK && data != null) {
                    // getStringExtra itself can throw for a malformed/hostile intent,
                    // so it stays inside its own guard as well.
                    val message = try {
                        data.getStringExtra(SmsRetriever.EXTRA_SMS_MESSAGE)
                    } catch (_: Throwable) {
                        null
                    }
                    if (message != null && !isFinishing && !isDestroyed) {
                        try {
                            channel?.invokeMethod("onOtpSmsReceived", message)
                        } catch (e: Exception) {
                            Log.w("MainActivity", "Failed to dispatch onOtpSmsReceived", e)
                        }
                    }
                }
            } catch (_: Throwable) {}
        }
    }

    override fun onDestroy() {
        isConsentInFlight = false
        unregisterSmsReceiver()
        super.onDestroy()
    }

    /**
     * Tells the Dart side that a permission request has been answered.
     *
     * The request itself returns before the dialog is answered — the system
     * dialog is asynchronous — so a Dart side that re-reads the permission
     * straight after asking reads the *old* answer and reports the grant as
     * still missing. The app would then keep showing a warning for a
     * permission the student has already given.
     *
     * So the answer is announced here, when it is actually known.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        channel?.invokeMethod("permissionChanged", requestCode)
    }

    companion object {
        const val CHANNEL_NAME = "ir.ac.uk.bahonar_nut/platform"
        const val SMS_CONSENT_REQUEST = 1002
        var pendingInitialDeepLink: String? = null
        fun consumeInitialDeepLink(): String? {
            val link = pendingInitialDeepLink
            pendingInitialDeepLink = null
            return link
        }
    }
}
