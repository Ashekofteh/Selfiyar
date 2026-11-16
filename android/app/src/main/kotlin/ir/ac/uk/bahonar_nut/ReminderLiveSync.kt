package ir.ac.uk.bahonar_nut

import android.content.Context
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The optional live sync that runs before a reminder is delivered when the app
 * is closed.
 *
 * ## Two modes, one rule
 *
 * * `liveCheckEnabled == false`: the reminder is composed from `meals.held`
 *   alone. Nothing touches the network, so the notification works on a plane,
 *   in a tunnel, and when the portal is down.
 * * `liveCheckEnabled == true`: the reminder tries to refresh the mirror from
 *   the portal first, but only within a strict budget. A login failure, a
 *   network error, or a slow portal falls back to the offline store, and the
 *   reminder still speaks.
 *
 * The setting is the student's: the offline path is not a degraded mode, it is
 * the default.
 */
internal class ReminderLiveSync(private val context: Context) {

    companion object {
        private const val TAG = "ReminderLiveSync"

        /**
         * How long the refresh may hold the delivery.
         *
         * The wait is bounded because a network read in Doze does not fail —
         * it hangs until Android opens a maintenance window, and a reminder
         * that waits for that window is a reminder that misses the meal. The
         * native wait is deliberately longer than the Dart entrypoint's own
         * budget (twelve seconds), leaving time for the store write and the
         * report back.
         */
        const val TIMEOUT_MILLIS = 18_000L
    }

    /**
     * Whether the configuration asks for a live refresh.
     *
     * A missing or unreadable configuration reads as "no": the safe default is
     * to deliver what is already on disk, not to hold the notification while a
     * guess is made.
     */
    fun isEnabled(): Boolean {
        return try {
            val config = ReminderConfigStoreReader.read(context) ?: return false
            config.masterEnabled && config.liveCheckEnabled
        } catch (e: Exception) {
            Log.w(TAG, "Could not read the live-check setting; staying offline", e)
            false
        }
    }

    /**
     * Starts the headless sync and calls [onReady] once the store is as fresh
     * as it is going to get.
     *
     * [onReady] is called on a background thread, and at most once. It is
     * called immediately when the engine cannot start, after the sync reports
     * back, and when [TIMEOUT_MILLIS] expires — whichever comes first.
     *
     * Must be called on the main thread, because a [ReminderSyncEngine] creates
     * a Flutter engine.
     *
     * Returns whether a sync was actually started. A false means [onReady] has
     * already been called and the caller should deliver from the offline store.
     */
    fun syncThen(onReady: () -> Unit): Boolean {
        val once = AtomicBoolean(false)
        val ready = {
            if (once.compareAndSet(false, true)) {
                try {
                    onReady()
                } catch (e: Exception) {
                    Log.e(TAG, "The reminder delivery after sync failed", e)
                }
            }
        }

        val engine = ReminderSyncEngine(context)
        val finished = CountDownLatch(1)

        val started = engine.start {
            // The Dart side has written the store and reported back.
            finished.countDown()
        }

        if (!started) {
            // The engine's own failure callback has already counted the latch
            // down; nothing was refreshed, so deliver from the offline store.
            ready()
            return false
        }

        Thread(
            {
                try {
                    if (!finished.await(TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)) {
                        Log.w(
                            TAG,
                            "The live reminder sync timed out; delivering from the offline store",
                        )
                    }
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                } finally {
                    engine.destroy()
                    ready()
                }
            },
            "reminder-live-sync",
        ).start()

        return true
    }
}
