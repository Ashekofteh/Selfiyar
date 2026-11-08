package ir.ac.uk.bahonar_nut

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
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

    private val smsVerificationReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (SmsRetriever.SMS_RETRIEVED_ACTION == intent.action) {
                val extras = intent.extras ?: return
                val smsRetrieverStatus = extras.get(SmsRetriever.EXTRA_STATUS) as? Status
                when (smsRetrieverStatus?.statusCode) {
                    CommonStatusCodes.SUCCESS -> {
                        val consentIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            extras.getParcelable(SmsRetriever.EXTRA_CONSENT_INTENT, Intent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            extras.getParcelable(SmsRetriever.EXTRA_CONSENT_INTENT)
                        }
                        try {
                            if (consentIntent != null) {
                                startActivityForResult(consentIntent, SMS_CONSENT_REQUEST)
                            }
                        } catch (e: ActivityNotFoundException) {
                            // Consent activity not available on this device
                        }
                    }
                    CommonStatusCodes.TIMEOUT -> {
                        unregisterSmsReceiver()
                    }
                }
            }
        }
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

    fun registerSmsReceiver() {
        if (isSmsReceiverRegistered) return
        val intentFilter = IntentFilter(SmsRetriever.SMS_RETRIEVED_ACTION)
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
    }

    fun unregisterSmsReceiver() {
        if (!isSmsReceiverRegistered) return
        try {
            unregisterReceiver(smsVerificationReceiver)
        } catch (_: Exception) {}
        isSmsReceiverRegistered = false
    }

    fun startSmsUserConsent(result: MethodChannel.Result) {
        try {
            registerSmsReceiver()
            SmsRetriever.getClient(this).startSmsUserConsent(null)
                .addOnSuccessListener {
                    result.success(true)
                }
                .addOnFailureListener { e ->
                    unregisterSmsReceiver()
                    result.error("SMS_RETRIEVER_ERROR", e.message, null)
                }
        } catch (e: Exception) {
            unregisterSmsReceiver()
            result.error("SMS_RETRIEVER_ERROR", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SMS_CONSENT_REQUEST) {
            unregisterSmsReceiver()
            if (resultCode == Activity.RESULT_OK && data != null) {
                val message = data.getStringExtra(SmsRetriever.EXTRA_SMS_MESSAGE)
                if (message != null) {
                    channel?.invokeMethod("onOtpSmsReceived", message)
                }
            }
        }
    }

    override fun onDestroy() {
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
