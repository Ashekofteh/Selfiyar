package ir.ac.uk.bahonar_nut

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * The foreground service that keeps a hunt alive.
 *
 * ## Why a foreground service at all
 *
 * A hunt is a burst of network requests over a window of minutes, and it has
 * to survive the screen going off and the device dozing. A background
 * `WorkManager` job is not enough: the system may defer it past the very
 * cutoff it is trying to hit. A foreground service is the only mechanism
 * Android offers that is reliably exempt from Doze.
 *
 * ## Why it is released promptly
 *
 * The spec is explicit: the service is released the moment the window closes
 * or a purchase lands. A foreground service that lingers is a battery drain
 * and a user-visible notification that will not go away, so `stopForeground`
 * is called on every exit path, including the failure ones.
 *
 * The service itself holds no logic. It keeps the process alive and asks the
 * Dart side to run; every decision about *whether* to buy belongs to the
 * domain core.
 */
class HuntService : Service() {

    companion object {
        const val ACTION_START = "ir.ac.uk.bahonar_nut.HUNT_START"
        const val ACTION_STOP = "ir.ac.uk.bahonar_nut.HUNT_STOP"
        const val EXTRA_PAYLOAD = "payload"

        /**
         * Whether the start came from the Dart side.
         *
         * The Dart side already knows it asked for the hunt, so it does not
         * need to be told, and — more importantly — it must not be *recorded*
         * as a request it still owes. Without this flag every hunt the
         * student starts by hand would leave a pending request behind, and
         * the next launch would start the hunt a second time.
         */
        const val EXTRA_FROM_DART = "fromDart"

        private const val FOREGROUND_ID = 4201

        /** Accounts whose hunt currently needs this foreground service alive. */
        internal val active = linkedSetOf<String>()

        internal fun registerAccount(accountId: String?) {
            if (!accountId.isNullOrBlank()) {
                active.add(accountId)
            }
        }

        internal fun unregisterAccount(accountId: String?): Boolean {
            if (accountId == null) {
                active.clear()
                return true
            }
            active.remove(accountId)
            return active.isEmpty()
        }

        /**
         * Starts the service, optionally with a payload describing the hunt.
         *
         * [fromDart] marks the start as the Dart side's own request. Every
         * other start is the platform asking on its own behalf, and those
         * are the ones that have to be recorded.
         */
        fun start(context: Context, payload: String?, fromDart: Boolean = false) {
            registerAccount(payload)
            val intent = Intent(context, HuntService::class.java).apply {
                action = ACTION_START
                if (payload != null) putExtra(EXTRA_PAYLOAD, payload)
                putExtra(EXTRA_FROM_DART, fromDart)
            }
            context.startForegroundService(intent)
        }

        /**
         * Releases one account, or the whole service when [accountId] is null
         * (an explicit user "stop everything").
         */
        fun stop(context: Context, accountId: String? = null) {
            if (unregisterAccount(accountId)) {
                context.stopService(Intent(context, HuntService::class.java))
            }
        }
    }

    private var notifier: ReminderNotifier? = null

    /**
     * The engine that runs the hunt when the app is closed.
     *
     * Null when the hunt was started by the app's own Dart side, or when no
     * background engine could be started.
     */
    private var background: BackgroundHuntEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notifier = ReminderNotifier(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        // The service must post its notification within a few seconds of
        // startForegroundService, or the system kills the app for not doing so.
        startForeground(FOREGROUND_ID, notifier?.buildServiceNotification())

        val payload = intent?.getStringExtra(EXTRA_PAYLOAD)
        val fromDart = intent?.getBooleanExtra(EXTRA_FROM_DART, false) ?: false

        // The Dart side owns the hunt; it is told through the same channel the
        // rest of the platform bridge uses.
        //
        // A start the **Dart side** asked for is not recorded and not
        // announced back: the Dart side knows it asked, so a record would make
        // it start the hunt a second time on the next launch, and an
        // announcement would bounce straight back into the handler that made
        // the call.
        //
        // Every other start is the platform asking on its own behalf, and
        // those are the ones that have to be recorded. The channel is a static
        // field the activity populates, so with a dead process the
        // announcement below was a no-op: the service started, posted its
        // notification, and told nobody. The hunt never ran, and the
        // notification sat on screen claiming the app was monitoring the
        // basket.
        //
        // The record is written **first**, before anybody is asked. That is
        // the F75 rule — "record, don't deliver" — and it is the safety net:
        // if the process dies between the alarm and the hand-over, the hunt
        // is still owed, and the next launch runs it.
        //
        // The cost of recording first is that the record outlives a hunt
        // that *did* run, and the next launch would start a second one. So
        // the side that acts clears the record: the in-app path does it
        // through the pending-request sweep, and the background engine does
        // it in the headless entrypoint. Both are the same rule — the record
        // is cleared by the side that knows the outcome.
        if (!fromDart) {
            PendingRequest.record(this, PendingRequest.KIND_HUNT, payload)

            val delivered = PlatformChannelMessenger.notifyHuntRequested(this, payload)

            if (!delivered) {
                // There was no Dart side to hand the hunt to — the app was
                // closed, which is the whole reason the alarm fired. So the
                // hunt gets a Dart side of its own: a second engine, whose
                // Dart is a root isolate and can therefore use the method
                // channel.
                val started = startBackgroundHunt(payload)

                if (!started) {
                    // The background engine could not start, so nothing is
                    // running. The service stops rather than sit on the screen
                    // claiming to monitor the basket: a foreground service
                    // with no hunt behind it is a battery drain and a
                    // notification the user cannot clear. The request stays
                    // owed, and the hunt starts when the app next runs.
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }

        // START_STICKY would restart the service with a null intent after a
        // kill. The hunt is re-armed by the alarm instead, so NOT_STICKY is
        // correct: a stale service restart could re-run a hunt whose window
        // has closed.
        return START_NOT_STICKY
    }

    /**
     * Starts the background engine for the hunt.
     *
     * Returns whether the engine is running the hunt. A false means the hunt
     * cannot run headless, and the request stays owed.
     */
    private fun startBackgroundHunt(payload: String?): Boolean {
        val engine = BackgroundHuntEngine(this)
        if (!engine.start(payload)) return false
        background = engine
        return true
    }

    override fun onDestroy() {
        active.clear()
        // The engine dies with the service. A second Flutter engine is a
        // second Dart VM, and a VM held for nothing is a battery drain — so
        // the hunt's lifetime and the engine's lifetime are the same.
        background?.destroy()
        background = null

        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}

/**
 * The singleton bridge instance, so the service can reach the Dart side.
 *
 * The service and the activity live in the same process, so a static holder is
 * sufficient and avoids the ceremony of binding.
 *
 * ## The channel may be absent
 *
 * The channel is attached by the activity, so it is null whenever the process
 * is alive but the app has not been opened. Every method here therefore
 * reports whether it reached a Dart side, because a caller that was silently
 * ignored is worse than one that was told it failed.
 */
object PlatformChannelMessenger {
    private var channel: io.flutter.plugin.common.MethodChannel? = null
    private var notifier: ReminderNotifier? = null
    private var alarms: AlarmScheduler? = null

    fun attach(
        channel: io.flutter.plugin.common.MethodChannel,
        notifier: ReminderNotifier,
        alarms: AlarmScheduler,
    ) {
        this.channel = channel
        this.notifier = notifier
        this.alarms = alarms
    }

    /**
     * Asks the Dart side to run a hunt.
     *
     * Returns whether there was a Dart side to ask. A false means the request
     * was lost, and the caller must record it instead.
     */
    fun notifyHuntRequested(context: Context, payload: String?): Boolean {
        val target = channel ?: return false
        target.invokeMethod("huntRequested", payload)
        return true
    }

    /**
     * Tells the Dart side a reminder alarm fired.
     *
     * A separate method from [notifyHuntRequested], because the two mean
     * different things and the Dart side treats them differently: a hunt
     * starts a foreground service, a reminder delivers a digest and re-arms
     * itself.
     *
     * Returns whether there was a Dart side to ask.
     */
    fun notifyReminderFired(payload: String?): Boolean {
        val target = channel ?: return false
        target.invokeMethod("reminderFired", payload)
        return true
    }

    /**
     * Tells the Dart side that the alarms were cleared and must be re-armed.
     *
     * Returns whether there was a Dart side to ask.
     */
    fun notifyRebootRequired(context: Context): Boolean {
        val target = channel ?: return false
        target.invokeMethod("rebootCompleted", null)
        return true
    }

    /** Posts a notification from the Dart side. */
    fun postNotification(id: Int, title: String, body: String, deepLink: String?) {
        notifier?.post(id, title, body, deepLink)
    }
}
