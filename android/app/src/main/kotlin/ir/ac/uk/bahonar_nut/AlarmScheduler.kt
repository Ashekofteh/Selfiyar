package ir.ac.uk.bahonar_nut

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

/**
 * Schedules the reminder alarms.
 *
 * ## Why exact alarms
 *
 * A reminder at 10:30 that arrives at 11:20 is useless, and the window it
 * guards closes at 20:00 the same day. `AlarmManager.setExactAndAllowWhileIdle`
 * is the only API that fires at the requested minute, including in Doze.
 *
 * The permission (`SCHEDULE_EXACT_ALARM`, Android 12+) is requested **with an
 * explanation**, never silently: the user is told that exact timing is what
 * makes the reminder useful, and that the alternative — inexact alarms — can be
 * delayed by hours and may miss a cutoff entirely.
 *
 * ## The catch-up
 *
 * Exact alarms are lost when the device is off. A `WorkManager` job is
 * scheduled alongside as a backstop, and a boot receiver re-arms everything.
 * Without that, a phone that was off at 20:00 would silently fail to reserve
 * the weekend's meals.
 */
class AlarmScheduler(private val context: Context) {

    private val alarmManager: AlarmManager =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    /**
     * Arms [pendingIntent] at [triggerAtMillis], exactly when the app is
     * allowed to and as a windowed alarm otherwise.
     *
     * The decision itself lives in [AlarmPlan] so it can be unit-tested on the
     * JVM: `AlarmManager` has no JVM implementation, but the choice between
     * `setExactAndAllowWhileIdle` and `setWindow` is ordinary logic and is the
     * part that silently regressed before.
     */
    private fun arm(triggerAtMillis: Long, pendingIntent: PendingIntent) {
        when (val plan = AlarmPlan.forTrigger(canScheduleExact(), triggerAtMillis)) {
            is AlarmPlan.Exact -> alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                plan.triggerAtMillis,
                pendingIntent,
            )

            is AlarmPlan.Inexact -> alarmManager.setWindow(
                AlarmManager.RTC_WAKEUP,
                plan.triggerAtMillis,
                plan.windowMillis,
                pendingIntent,
            )
        }
    }

    /** Whether exact alarms are currently permitted. */
    fun canScheduleExact(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return alarmManager.canScheduleExactAlarms()
    }

    /**
     * Sends the user to the system setting that grants exact alarms.
     *
     * The request code is fixed so the setting opens once, not per call.
     */
    fun requestExactAlarmPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(true)
            return
        }
        if (canScheduleExact()) {
            result.success(true)
            return
        }
        try {
            val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                .setData(android.net.Uri.parse("package:${context.packageName}"))
            context.startActivity(intent)
        } catch (e: Exception) {
            // Some devices do not expose the screen; the app still works with
            // inexact alarms, just less precisely.
        }
        result.success(false)
    }

    /** Schedules an exact alarm at [triggerAtMillis]. */
    fun scheduleExact(requestCode: Int, triggerAtMillis: Long, payload: String?) {
        val intent = Intent(context, ReminderAlarmReceiver::class.java).apply {
            action = ACTION_REMINDER
            if (payload != null) putExtra(EXTRA_PAYLOAD, payload)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // Without the permission the alarm still fires, just not exactly.
        // A late reminder is better than none.
        arm(triggerAtMillis, pendingIntent)
    }

    fun cancel(requestCode: Int) {
        val intent = Intent(context, ReminderAlarmReceiver::class.java).apply {
            action = ACTION_REMINDER
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarmManager.cancel(pendingIntent)
    }

    /**
     * Schedules the hunt's wake-up for [accountId] at [triggerAtMillis].
     *
     * ## Why the hunt has its own action
     *
     * The reminder alarms and the hunt alarms are different things, and the
     * receiver has to tell them apart *before* the Dart side can be asked. The
     * reminder alarms carry a payload the Dart side defines ("lunch",
     * "evening", "nudge"); the hunt's carries an account id. Guessing from
     * the payload's shape would mean a payload the app did not recognise was
     * treated as a hunt — so the action says which it is, and the payload
     * only says which account.
     *
     * ## Why the account is in the intent's data, not only in its extra
     *
     * A `PendingIntent` is identified by its request code **and** its intent's
     * action, data, type and component — but not by its extras. So two
     * accounts' hunt alarms, sharing a request code and an intent, would be
     * the *same* pending intent: arming the second would silently replace
     * the first, and cancelling one would cancel both.
     *
     * Putting the account in the data URI makes each account's alarm a
     * distinct pending intent, so each can be armed, replaced and cancelled
     * on its own. The request code is then the same for all of them, and the
     * data does the distinguishing.
     */
    fun scheduleHunt(accountId: String, triggerAtMillis: Long) {
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            HUNT_REQUEST_CODE,
            huntIntent(accountId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // Without the permission the alarm still fires, just not exactly.
        // A late hunt is worth less than a punctual one — it may find the
        // market already empty — which is why the app asks for the
        // permission in the first place.
        arm(triggerAtMillis, pendingIntent)
    }

    /** Cancels the hunt's wake-up for [accountId]. */
    fun cancelHunt(accountId: String) {
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            HUNT_REQUEST_CODE,
            huntIntent(accountId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarmManager.cancel(pendingIntent)
    }

    /** The intent that identifies a hunt's wake-up for [accountId]. */
    private fun huntIntent(accountId: String): Intent =
        Intent(context, ReminderAlarmReceiver::class.java).apply {
            action = ACTION_HUNT
            // The data is part of the pending intent's identity, so each
            // account's alarm is its own.
            data = Uri.parse("bahonar-nut://hunt/${Uri.encode(accountId)}")
            putExtra(EXTRA_PAYLOAD, accountId)
        }

    companion object {
        const val ACTION_REMINDER = "ir.ac.uk.bahonar_nut.REMINDER"

        /** The hunt's own wake-up, which the receiver tells apart by action. */
        const val ACTION_HUNT = "ir.ac.uk.bahonar_nut.HUNT"

        const val EXTRA_PAYLOAD = "payload"

        /**
         * The request code every hunt alarm shares.
         *
         * The accounts are told apart by the intent's data, not by the
         * request code — see [scheduleHunt].
         */
        const val HUNT_REQUEST_CODE = 4300
    }
}

/**
 * How an alarm should be handed to `AlarmManager`.
 *
 * Deliberately free of Android types so the exact-or-window fallback is
 * testable as plain Kotlin. The fallback is not cosmetic: without
 * `SCHEDULE_EXACT_ALARM`, Android may delay a windowed alarm by hours, which
 * can miss a meal cutoff entirely.
 */
internal sealed interface AlarmPlan {
    data class Exact(val triggerAtMillis: Long) : AlarmPlan

    data class Inexact(val triggerAtMillis: Long, val windowMillis: Long) : AlarmPlan

    companion object {
        /** How much an inexact alarm may drift: ten minutes. */
        const val INEXACT_WINDOW_MILLIS = 10 * 60 * 1000L

        /** Chooses the alarm API for [triggerAtMillis] from the permission. */
        fun forTrigger(canScheduleExact: Boolean, triggerAtMillis: Long): AlarmPlan =
            if (canScheduleExact) {
                Exact(triggerAtMillis)
            } else {
                Inexact(triggerAtMillis, INEXACT_WINDOW_MILLIS)
            }
    }
}
