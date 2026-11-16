package ir.ac.uk.bahonar_nut

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs the headless reminder sync in a short-lived Flutter engine.
 *
 * ## Why a second engine
 *
 * The live portal check is opt-in, and when it is on the reminder has to
 * refresh `meals.held` before it speaks. With the app closed there is no Dart
 * side to do that, and a spawned isolate cannot use the method channel — only
 * a root isolate gets a real binary messenger. A second `FlutterEngine`'s Dart
 * *is* a root isolate, so the same technique the headless hunt uses applies
 * here.
 *
 * ## The lifetime is one alarm
 *
 * The engine is created when the alarm fires and destroyed as soon as the
 * sync reports back — or when the caller's timeout expires. A second Dart VM
 * held open is a battery drain, so the engine never outlives the delivery it
 * was started for.
 *
 * ## Failure is not fatal
 *
 * If the engine cannot start, the Dart entrypoint throws, the network is
 * down, or the sync takes too long, the caller still delivers from the
 * offline mirror. A reminder is never dropped because a refresh failed.
 */
internal class ReminderSyncEngine(private val context: Context) {

    companion object {
        private const val TAG = "ReminderSyncEngine"

        /** The channel name the Dart side talks over. */
        const val CHANNEL_NAME = BackgroundHuntEngine.CHANNEL_NAME

        /**
         * The Dart library the headless reminder sync lives in.
         *
         * Named rather than implied: the engine runs this entrypoint, not the
         * app's `main`, because the app's `main` builds a widget tree and
         * shows a screen. A background refresh has no screen.
         */
        const val ENTRYPOINT_LIBRARY = "package:bahonar_nut/background/reminder_entrypoint.dart"

        /** The function the engine calls. It takes no arguments. */
        const val ENTRYPOINT_FUNCTION = "main"
    }

    private var engine: FlutterEngine? = null

    private val finished = AtomicBoolean(false)

    /** Whether the engine is still alive. */
    val isRunning: Boolean get() = engine != null

    /**
     * Starts the background engine and runs the headless sync.
     *
     * [onFinished] is called exactly once: when the Dart side reports that the
     * refresh is over, or immediately when the engine could not start. The
     * caller owns the timeout; this class only reports what it knows.
     *
     * Returns whether the engine was started.
     */
    fun start(onFinished: () -> Unit): Boolean {
        return try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)

            val created = FlutterEngine(context)
            engine = created

            val channel = MethodChannel(
                created.dartExecutor.binaryMessenger,
                CHANNEL_NAME,
            )
            channel.setMethodCallHandler(
                PlatformChannel(
                    context,
                    ReminderNotifier(context),
                    AlarmScheduler(context),
                    onReminderSyncFinished = {
                        notifyFinished(onFinished)
                    },
                ),
            )

            val bundlePath = loader.findAppBundlePath()
            val entrypoint = DartEntrypoint(
                bundlePath,
                ENTRYPOINT_LIBRARY,
                ENTRYPOINT_FUNCTION,
            )
            created.dartExecutor.executeDartEntrypoint(entrypoint, emptyList())

            Log.i(TAG, "the headless reminder sync engine is running")
            true
        } catch (e: Exception) {
            Log.e(TAG, "the headless reminder sync engine could not start", e)
            destroy()
            // The caller must still deliver from the offline store.
            notifyFinished(onFinished)
            false
        }
    }

    /** Reports completion once, whatever path got here first. */
    private fun notifyFinished(onFinished: () -> Unit) {
        if (!finished.compareAndSet(false, true)) return
        try {
            onFinished()
        } catch (e: Exception) {
            Log.e(TAG, "the reminder sync completion callback failed", e)
        }
    }

    /**
     * Destroys the engine and releases its Dart VM.
     *
     * `FlutterEngine.destroy` must run on the main thread; a receiver's
     * completion thread is not the main thread, so the call is posted.
     */
    fun destroy() {
        val current = engine ?: return
        engine = null
        val destroy: () -> Unit = {
            try {
                current.destroy()
            } catch (e: Exception) {
                Log.e(TAG, "the reminder sync engine could not be destroyed", e)
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            destroy()
        } else {
            Handler(Looper.getMainLooper()).post(destroy)
        }
    }
}
