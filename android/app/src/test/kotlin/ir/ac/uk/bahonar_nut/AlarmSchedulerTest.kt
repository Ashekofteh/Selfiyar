package ir.ac.uk.bahonar_nut

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The reminder and hunt alarms both fall back from
 * `setExactAndAllowWhileIdle` to `setWindow` when exact alarms are not
 * permitted. That choice is extracted into [AlarmPlan] precisely so it can be
 * checked here: a regression would not fail to compile, it would just make
 * reminders arrive late — or as a `setWindow` call with a nonsensical window.
 */
class AlarmSchedulerTest {

    @Test
    fun `an allowed exact alarm keeps the requested trigger time`() {
        val plan = AlarmPlan.forTrigger(
            canScheduleExact = true,
            triggerAtMillis = 1_766_000_000_000L,
        )

        assertEquals(AlarmPlan.Exact(1_766_000_000_000L), plan)
    }

    @Test
    fun `a denied exact alarm falls back to a ten minute window`() {
        val plan = AlarmPlan.forTrigger(
            canScheduleExact = false,
            triggerAtMillis = 1_766_000_000_000L,
        )

        assertEquals(
            AlarmPlan.Inexact(
                triggerAtMillis = 1_766_000_000_000L,
                windowMillis = 10 * 60 * 1000L,
            ),
            plan,
        )
    }

    @Test
    fun `the fallback window is ten minutes, not zero and not a day`() {
        assertEquals(600_000L, AlarmPlan.INEXACT_WINDOW_MILLIS)
    }

    @Test
    fun `the fallback never drops or shifts the requested trigger time`() {
        val plan = AlarmPlan.forTrigger(canScheduleExact = false, triggerAtMillis = 42L)

        assertTrue(plan is AlarmPlan.Inexact)
        assertEquals(42L, (plan as AlarmPlan.Inexact).triggerAtMillis)
    }

    @Test
    fun `the two plans are distinct so a fallback cannot be mistaken for an exact alarm`() {
        val exact = AlarmPlan.forTrigger(canScheduleExact = true, triggerAtMillis = 7L)
        val inexact = AlarmPlan.forTrigger(canScheduleExact = false, triggerAtMillis = 7L)

        assertNotEquals(exact, inexact)
    }
}
