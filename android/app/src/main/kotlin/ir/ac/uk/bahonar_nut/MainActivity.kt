package ir.ac.uk.bahonar_nut

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var notifier: ReminderNotifier? = null
    private var alarms: AlarmScheduler? = null

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
        var pendingInitialDeepLink: String? = null
        fun consumeInitialDeepLink(): String? {
            val link = pendingInitialDeepLink
            pendingInitialDeepLink = null
            return link
        }
    }
}
