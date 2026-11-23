package ir.ac.uk.bahonar_nut

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * The boot re-arm is the path that has to work when nothing else does: the
 * device has restarted, every alarm is gone, and the app is not running.
 *
 * These tests exercise [BootRearm] and the trigger arithmetic behind it — the
 * part that silently regresses if the configuration stops being readable or a
 * date is computed in the device's timezone instead of the portal's.
 */
class BootReceiverTest {

    /** A portal-local wall clock, as epoch millis. Month is 1-based. */
    private fun portal(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
    ): Long = Calendar.getInstance(portalTimeZone()).apply {
        clear()
        set(year, month - 1, day, hour, minute, 0)
    }.timeInMillis

    private fun alarmFor(plan: BootRearmPlan, requestCode: Int): ReminderAlarmPlan? =
        plan.alarms.firstOrNull { it.requestCode == requestCode }

    @Test
    fun `an unreadable configuration asks Dart to reconcile instead of guessing`() {
        val plan = BootRearm.plan(config = null, nowMillis = portal(2026, 10, 19, 9, 0))

        assertTrue(plan.needsDartReconciliation)
        assertTrue(plan.alarms.isEmpty())
    }

    @Test
    fun `a readable configuration never leaves the re-arm owed to Dart`() {
        val plan = BootRearm.plan(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertFalse(plan.needsDartReconciliation)
        assertTrue(plan.alarms.isNotEmpty())
    }

    @Test
    fun `every reminder alarm is cancelled before the new plan is armed`() {
        assertEquals(
            listOf(
                ReminderAlarmCodes.LUNCH,
                ReminderAlarmCodes.EVENING,
                ReminderAlarmCodes.NUDGE,
            ),
            BootRearm.allRequestCodes,
        )
    }

    @Test
    fun `the default slots are armed at their portal local times`() {
        val plan = BootRearm.plan(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            nowMillis = portal(2026, 10, 19, 9, 0), // Monday 09:00
        )

        assertEquals(
            portal(2026, 10, 19, 10, 30),
            alarmFor(plan, ReminderAlarmCodes.LUNCH)?.triggerAtMillis,
        )
        assertEquals(
            portal(2026, 10, 19, 16, 30),
            alarmFor(plan, ReminderAlarmCodes.EVENING)?.triggerAtMillis,
        )
        // The first nudge check of the week is Wednesday noon.
        assertEquals(
            portal(2026, 10, 21, 12, 0),
            alarmFor(plan, ReminderAlarmCodes.NUDGE)?.triggerAtMillis,
        )
    }

    @Test
    fun `a slot whose time has passed is armed for tomorrow`() {
        val plan = BootRearm.plan(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            nowMillis = portal(2026, 10, 19, 11, 0), // after lunch
        )

        assertEquals(
            portal(2026, 10, 20, 10, 30),
            alarmFor(plan, ReminderAlarmCodes.LUNCH)?.triggerAtMillis,
        )
    }

    @Test
    fun `an account excluded from a slot leaves that slot unarmed`() {
        val plan = BootRearm.plan(
            ReminderConfigSnapshot(
                accountIds = setOf("a1"),
                excludedFromSlot = mapOf("lunch" to setOf("a1")),
            ),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertEquals(null, alarmFor(plan, ReminderAlarmCodes.LUNCH))
        assertTrue(alarmFor(plan, ReminderAlarmCodes.EVENING) != null)
    }

    @Test
    fun `the master switch off arms nothing and records no re-arm`() {
        val plan = BootRearm.plan(
            ReminderConfigSnapshot(
                masterEnabled = false,
                accountIds = setOf("a1"),
            ),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )

        assertFalse(plan.needsDartReconciliation)
        assertTrue("a deliberate silence must not be recorded as owed", plan.alarms.isEmpty())
    }

    @Test
    fun `the nudge is not re-armed after Thursday evening`() {
        val plan = BootRearm.plan(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            nowMillis = portal(2026, 10, 22, 18, 0), // Thursday 18:00
        )

        assertEquals(null, alarmFor(plan, ReminderAlarmCodes.NUDGE))
        // The daily slots still continue; only the nudge window has closed.
        assertTrue(alarmFor(plan, ReminderAlarmCodes.LUNCH) != null)
    }

    @Test
    fun `the trigger is computed in portal time, not the device timezone`() {
        // 10:30 in GMT+03:30 is 07:00 UTC. A device set to another timezone
        // must not shift the digest to its own 10:30.
        val plan = BootRearm.plan(
            ReminderConfigSnapshot(accountIds = setOf("a1")),
            nowMillis = portal(2026, 10, 19, 9, 0),
        )
        val trigger = alarmFor(plan, ReminderAlarmCodes.LUNCH)!!.triggerAtMillis

        val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            timeInMillis = trigger
        }
        assertEquals(7, utc.get(Calendar.HOUR_OF_DAY))
        assertEquals(0, utc.get(Calendar.MINUTE))
    }

    @Test
    fun `the next nudge check steps through Wednesday and Thursday`() {
        assertEquals(
            portal(2026, 10, 21, 16, 0),
            NativeReminderSchedule.nextNudgeCheckMillis(portal(2026, 10, 21, 12, 0)),
        )
        assertEquals(
            portal(2026, 10, 21, 21, 0),
            NativeReminderSchedule.nextNudgeCheckMillis(portal(2026, 10, 21, 16, 0)),
        )
        assertEquals(
            portal(2026, 10, 22, 9, 0),
            NativeReminderSchedule.nextNudgeCheckMillis(portal(2026, 10, 21, 22, 0)),
        )
        assertEquals(
            portal(2026, 10, 22, 16, 30),
            NativeReminderSchedule.nextNudgeCheckMillis(portal(2026, 10, 22, 12, 0)),
        )
        assertEquals(
            null,
            NativeReminderSchedule.nextNudgeCheckMillis(portal(2026, 10, 22, 16, 30)),
        )
        assertEquals(
            null,
            NativeReminderSchedule.nextNudgeCheckMillis(portal(2026, 10, 22, 17, 0)),
        )
    }
}
