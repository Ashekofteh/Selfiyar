package ir.ac.uk.bahonar_nut

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives the reminder alarm and hands it to the Dart side.
 *
 * ## Two different alarms, two different destinations
 *
 * The app arms two kinds of alarm, and they are not the same thing:
 *
 *  * A **reminder** alarm (`lunch`, `evening`) asks the Dart side to deliver
 *    a digest. The digest is composed in Dart, from the local meal mirror, so
 *    the receiver hands the payload to the engine and stops.
 *  * A **hunt** wake-up starts the hunt's foreground service, which keeps the
 *    process alive for the length of the hunt.
 *
 * Treating a reminder as a hunt wake-up would post the "monitoring the food
 * basket" notification and leave a foreground service running with no hunt
 * behind it — a stuck notification the user cannot clear.
 *
 * ## Why the payload is recorded before it is handed over
 *
 * The alarm fires when the app may not be running, and the digest lives in
 * Dart. So the payload is written to [PendingDelivery] **first**, and only
 * then handed to the Dart side.
 *
 * The order matters. Handing it over first would lose the delivery whenever
 * the process was dead — the channel is a static field the activity
 * populates, so with a dead process the call was a no-op and the reminder
 * was dropped without a sound. Recording first means the delivery is owed
 * either way: the Dart side delivers it now if it is alive, and the record
 * is still there for it to pick up if it is not.
 */
class ReminderAlarmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val payload = intent.getStringExtra(AlarmScheduler.EXTRA_PAYLOAD)

        // The **action** says which kind of alarm this is, not the payload's
        // shape.
        //
        // The old code told a reminder from a hunt by asking whether the
        // payload was one of the three the app knows — and treated everything
        // else as a hunt. That made an unrecognised payload a hunt wake-up,
        // which is how a reminder that went missing could have started a
        // hunt for an account nobody named. The action is unambiguous: the
        // app arms a hunt with ACTION_HUNT and a reminder with
        // ACTION_REMINDER, and nothing else.
        if (intent.action == AlarmScheduler.ACTION_HUNT) {
            // A hunt wake-up. The service records the request itself — it is
            // the one that has to decide whether a Dart side was there to take
            // it.
            HuntService.start(context, payload)
            return
        }

        if (ReminderPayloads.isReminder(payload)) {
            val delivered = PlatformChannelMessenger.notifyReminderFired(payload)
            if (delivered) {
                return
            }

            // The Flutter engine is not running (app is closed/backgrounded).
            // 1. Record as backstop in case native delivery fails:
            PendingDelivery.record(context, payload!!)

            // 2. Deliver immediately via native Android notifications so the user
            // gets the reminder on time on their lock screen / status bar:
            NativeReminderDelivery.deliver(context, payload)
            return
        }

        // An alarm the app does not recognise. Nothing is started and nothing
        // is recorded: an unknown alarm is not a hunt.
    }
}

/**
 * The payload vocabulary shared with the Dart side.
 *
 * The Dart side owns what a payload means, but the receiver has to decide
 * *which* path a payload takes before the Dart side is reachable — so the
 * split is stated here, once, and the Dart side matches it.
 */
object ReminderPayloads {
    /** The lunch digest. */
    const val LUNCH = "lunch"

    /** The evening digest (dinner and tomorrow's breakfast). */
    const val EVENING = "evening"

    /** The next-week reservation nudge. */
    const val NUDGE = "nudge"

    /** Whether the payload names a reminder rather than a hunt. */
    fun isReminder(payload: String?): Boolean =
        payload == LUNCH || payload == EVENING || payload == NUDGE
}
