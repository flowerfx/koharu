package com.kurubyinteractive.aimanga.data

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.kurubyinteractive.aimanga.MainActivity
import com.kurubyinteractive.aimanga.R
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Local reminder when the daily reward resets (00:00 UTC), shown in the
 * user's local time. The app records the signed-in account's daily amount
 * (10 Free / 100 Premium from the server policy); without an account no
 * reminder is scheduled.
 */
object DailyReminder {
    private const val CHANNEL = "daily_reward"
    private const val NOTIFICATION = 1001
    const val EXTRA_OPEN_DAILY = "open_daily_reward"

    private fun prefs(context: Context) = context.getSharedPreferences("daily_reminder", Context.MODE_PRIVATE)

    fun enabled(context: Context): Boolean = prefs(context).getBoolean("enabled", true)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean("enabled", enabled).apply()
        schedule(context)
    }

    /** Records today's amount for the signed-in account, or clears it on sign-out. */
    fun remember(context: Context, daily: Int?) {
        prefs(context).edit().apply { if (daily == null) remove("daily") else putInt("daily", daily) }.apply()
        schedule(context)
    }

    /** The next reset, 00:00 UTC, in the device's time zone. */
    fun nextReset(): ZonedDateTime =
        LocalDate.now(ZoneOffset.UTC).plusDays(1).atStartOfDay(ZoneOffset.UTC).withZoneSameInstant(ZoneId.systemDefault())

    fun localResetTime(): String = nextReset().format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT))

    fun schedule(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val intent = PendingIntent.getBroadcast(
            context, 0, Intent(context, DailyReminderReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        alarms.cancel(intent)
        if (!enabled(context) || !prefs(context).contains("daily")) return
        // Inexact within 10 minutes after the reset: no exact-alarm permission needed.
        val at = nextReset().toInstant().toEpochMilli() + 60_000
        alarms.setWindow(AlarmManager.RTC_WAKEUP, at, 10 * 60_000L, intent)
    }

    fun show(context: Context) {
        val daily = prefs(context).getInt("daily", -1)
        if (!enabled(context) || daily < 0) return
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.reminder_channel), NotificationManager.IMPORTANCE_DEFAULT),
        )
        val open = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).putExtra(EXTRA_OPEN_DAILY, true).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_reward)
            .setContentTitle(context.getString(R.string.reminder_title))
            .setContentText(context.getString(R.string.reminder_body, daily, localResetTime()))
            .setStyle(NotificationCompat.BigTextStyle().bigText(context.getString(R.string.reminder_body, daily, localResetTime())))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(NOTIFICATION, notification) }
    }
}

/** Fires at the daily reset (and after a reboot, to reschedule). */
class DailyReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) DailyReminder.show(context)
        DailyReminder.schedule(context)
    }
}
