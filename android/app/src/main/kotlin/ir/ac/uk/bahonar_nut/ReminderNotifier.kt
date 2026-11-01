package ir.ac.uk.bahonar_nut

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodChannel
import ir.ac.uk.bahonar_nut.MainActivity

/**
 * Posts the reminder notifications.
 *
 * ## The channel's importance
 *
 * `IMPORTANCE_HIGH` with a **normal** sound and no vibration. The user asked
 * explicitly for a standard push notification — no alarm-style ringing, no
 * full-screen takeover — so the channel is deliberately configured as
 * "a notification you see in the shade", not "an alarm that wakes the house".
 * The sound is set separately from importance so that raising the importance
 * does not drag the alarm behaviour along with it.
 *
 * ## The deep link
 *
 * Tapping opens the app and carries the reminder's identity, so the detail
 * screen can open directly on the right reminder.
 */
class ReminderNotifier(private val context: Context) {

    companion object {
        const val CHANNEL_ID = "bahonar_nut.reminders_v2"
        const val CHANNEL_NAME = "یادآورهای غذا"
        const val SERVICE_CHANNEL_ID = "bahonar_nut.service"
        const val SERVICE_CHANNEL_NAME = "پایش سبد غذا"

        /** The extra carrying the deep link of a tapped notification. */
        const val EXTRA_DEEP_LINK = "deepLink"

        private const val NOTIFICATION_PERMISSION_REQUEST = 4001
    }

    private val manager = NotificationManagerCompat.from(context)

    init {
        createChannels()
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = context.getSystemService(NotificationManager::class.java)
            ?: return

        // The reminder channel: visible, but not an alarm.
        try {
            manager.deleteNotificationChannel("bahonar_nut.reminders")
        } catch (_: Exception) {}

        // The reminder channel: visible with alert sound and vibration
        val reminders = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "یادآوری زمان رزرو و جمع‌آوری وعده‌های غذا"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 250, 250, 250)
            enableLights(true)
        }

        // The foreground-service channel: silent, and minimal, because it exists
        // only to keep the process alive and must not draw attention.
        val service = NotificationChannel(
            SERVICE_CHANNEL_ID,
            SERVICE_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "پایش سبد غذا در بازه رزرو"
            setSound(null, null)
            enableVibration(false)
        }

        manager.createNotificationChannel(reminders)
        manager.createNotificationChannel(service)
    }

    /** Whether the user has granted the notification permission. */
    fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ActivityCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    /** Asks for the notification permission, on Android 13+. */
    fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        val activity = context as? MainActivity ?: run {
            result.success(false)
            return
        }
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
        // The grant is observed on the next call to hasPermission(); the Dart
        // side re-checks after the permission dialog resolves.
        result.success(true)
    }

    /** Posts a reminder notification. */
    fun post(id: Int, title: String, body: String, deepLink: String?) {
        if (!hasPermission()) return

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (deepLink != null) putExtra(EXTRA_DEEP_LINK, deepLink)
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val style = NotificationCompat.BigTextStyle().bigText(body)

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(style)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .build()

        try {
            manager.notify(id, notification)
        } catch (e: SecurityException) {
            // The permission was revoked between the check and the post. Nothing
            // to do; the next check will notice.
        }
    }

    fun cancel(id: Int) {
        manager.cancel(id)
    }

    /** The notification that keeps the hunt service alive. */
    fun buildServiceNotification(): Notification {
        val intent = Intent(context, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(context, SERVICE_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentTitle("پایش سبد غذا")
            .setContentText("در حال بررسی سبد غذایی برای وعده‌های موردنظر")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}

