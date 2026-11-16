package ir.ac.uk.bahonar_nut

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-arms the reminder alarms after a reboot or an app update.
 *
 * Android clears all alarms when the device restarts, so without this a phone
 * that was off overnight would silently fail to remind the user — and the
 * reminder is there to protect a cutoff that does not wait.
 *
 * ## Direct re-arm, with Dart only as a fallback
 *
 * The configuration lives in the same `SharedPreferences` the Dart side
 * writes (`reminders.config`), and the native side can read it without a Dart
 * runtime. So the receiver **re-arms the alarms itself** at boot. That is the
 * only path that reliably runs: at boot the process is by definition dead, and
 * the method channel that the old implementation asked is a static field the
 * activity populates.
 *
 * A `PendingRequest.KIND_REARM` is recorded **only** when the configuration is
 * absent or unreadable. In that case the native side must not guess — the Dart
 * side owns the settings — so the request stays owed until the next launch,
 * when the Dart side reconciles them.
 *
 * ## The times are the portal's
 *
 * Every trigger time is computed in `GMT+03:30` by [NativeReminderSchedule],
 * never in the device's timezone. A student travelling abroad must still get
 * the digest for the portal's day, not one shifted by their current offset.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        val plan = try {
            BootRearm.plan(
                ReminderConfigStoreReader.read(context),
                System.currentTimeMillis(),
            )
        } catch (e: Exception) {
            // A failure to read is the same as an unreadable configuration:
            // the Dart side has to reconcile it.
            Log.w(TAG, "Could not read the reminder configuration at boot", e)
            BootRearm.plan(null, System.currentTimeMillis())
        }

        // Cancelled first: a slot that is switched off must not keep the old
        // alarm that was armed before the reboot, and re-arming a subset
        // would otherwise leave the missing ones behind.
        try {
            val scheduler = AlarmScheduler(context)
            for (requestCode in BootRearm.allRequestCodes) {
                scheduler.cancel(requestCode)
            }
            for (alarm in plan.alarms) {
                scheduler.scheduleExact(
                    alarm.requestCode,
                    alarm.triggerAtMillis,
                    alarm.payload,
                )
            }
        } catch (e: Exception) {
            // If the alarms could not be armed, the Dart side still has to be
            // asked when it next runs. Marking the plan as owed is the only
            // way to keep the reminder alive after a failed boot re-arm.
            Log.e(TAG, "Failed to re-arm the reminder alarms", e)
            PendingRequest.record(context, PendingRequest.KIND_REARM, null)
            PlatformChannelMessenger.notifyRebootRequired(context)
            return
        }

        if (plan.needsDartReconciliation) {
            // The native side had no trustworthy configuration. The Dart side
            // owns the settings, so the re-arm is recorded for the next launch
            // — and announced in case the app happens to be alive already.
            PendingRequest.record(context, PendingRequest.KIND_REARM, null)
            PlatformChannelMessenger.notifyRebootRequired(context)
        } else if (plan.alarms.isEmpty()) {
            // A readable configuration that arms nothing (master off, every
            // slot off, or no accounts) is a deliberate silence, not a
            // failure: nothing is recorded and nothing is announced.
            Log.i(TAG, "Reminders are off; no alarm was armed at boot")
        } else {
            Log.i(TAG, "Re-armed ${plan.alarms.size} reminder alarm(s) at boot")
        }
    }

    private companion object {
        const val TAG = "BootReceiver"
    }
}
