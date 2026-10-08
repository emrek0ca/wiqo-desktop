package com.wiqo.android.data.automation

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
import com.wiqo.android.MainActivity
import com.wiqo.android.R
import com.wiqo.android.data.network.WiqoApi
import com.wiqo.android.data.security.SecureTokenStore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** Mirrors the backend's notification-only schedule. The server keeps delivery unless every
 * alarm for an automation is installed and the lease call succeeds. */
class LocalReminderCoordinator(
    private val context: Context,
    private val api: WiqoApi,
    private val tokens: SecureTokenStore,
) {
    private val lock = Mutex()

    suspend fun reconcile() = lock.withLock {
        val account = api.currentAccountId() ?: return@withLock
        if (tokens.read() == null || !canDeliver(context)) {
            clear()
            return@withLock
        }
        val root = api.get("automations/local-notifications") as? JsonObject ?: return@withLock
        val descriptors = ((root["notifications"] as? JsonArray).orEmpty() +
            (root["once"] as? JsonArray).orEmpty()).mapNotNull { it as? JsonObject }.take(64)
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        if (preferences.getString(ACCOUNT, null) != account) clear()
        val installed = preferences.getStringSet(INSTALLED, emptySet()).orEmpty().toList()
        installed.forEach { cancel(context, it) }
        val successful = mutableListOf<Int>()
        val saved = mutableSetOf<String>()
        val records = mutableSetOf<String>()
        for (descriptor in descriptors) {
            val id = descriptor.integer("automationId")?.takeIf { it > 0 } ?: continue
            val specs = expand(descriptor)
            if (specs.isEmpty() || saved.size + specs.size > 56) continue
            val added = mutableListOf<String>()
            for (spec in specs) {
                if (!install(context, spec)) break
                added += spec.key
            }
            if (added.size == specs.size) {
                successful += id
                saved += added
                records += specs.map { it.encode() }
            } else added.forEach { cancel(context, it) }
        }
        preferences.edit().putString(ACCOUNT, account).putStringSet(INSTALLED, saved)
            .putStringSet(RECORDS, records).commit()
        if (successful.isNotEmpty()) {
            api.post("automations/local-delivery", buildJsonObject {
                put("automationIds", JsonArray(successful.map(::JsonPrimitive)))
            })
        }
    }

    fun clear() {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        preferences.getStringSet(INSTALLED, emptySet()).orEmpty().forEach { cancel(context, it) }
        preferences.edit().clear().commit()
    }

    companion object {
        private const val PREFERENCES = "wiqo_local_reminders"
        private const val INSTALLED = "installed"
        private const val RECORDS = "records"
        private const val ACCOUNT = "account"
        private const val CHANNEL = "wiqo_reminders"

        private fun canDeliver(context: Context): Boolean {
            val notifications = Build.VERSION.SDK_INT < 33 ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            val exact = Build.VERSION.SDK_INT < 31 ||
                (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
            return notifications && NotificationManagerCompat.from(context).areNotificationsEnabled() && exact
        }

        private fun expand(row: JsonObject): List<ReminderSpec> {
            val id = row.integer("automationId") ?: return emptyList()
            val title = row.string("title")?.take(120) ?: return emptyList()
            val body = row.string("body")?.take(1000) ?: return emptyList()
            val hash = row.string("specHash").orEmpty()
            row.string("at")?.let { at ->
                val instant = runCatching { Instant.parse(at) }.getOrNull() ?: return emptyList()
                if (instant.toEpochMilli() <= System.currentTimeMillis() + 5_000) return emptyList()
                return listOf(ReminderSpec("$id.once", id, hash, title, body, null, null, null, null, instant.toEpochMilli()))
            }
            val hour = row.integer("hour")?.takeIf { it in 0..23 } ?: return emptyList()
            val minute = row.integer("minute")?.takeIf { it in 0..59 } ?: return emptyList()
            val timezone = row.string("timezone")?.takeIf { runCatching { ZoneId.of(it) }.isSuccess } ?: return emptyList()
            val weekdays = (row["weekdays"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }
            if (weekdays != null && (weekdays.isEmpty() || weekdays.any { it !in 0..6 })) return emptyList()
            return (weekdays ?: listOf(-1)).distinct().map { weekday ->
                ReminderSpec("$id.${if (weekday < 0) "daily" else weekday}", id, hash, title, body, hour, minute,
                    weekday.takeIf { it >= 0 }, timezone, null)
            }
        }

        private fun install(context: Context, spec: ReminderSpec): Boolean {
            if (!canDeliver(context)) return false
            val whenMs = spec.nextEpochMillis() ?: return false
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pending = pending(context, spec.key, spec) ?: return false
            return runCatching { alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMs, pending) }.isSuccess
        }

        private fun cancel(context: Context, key: String) {
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            pending(context, key, null)?.let { alarm.cancel(it); it.cancel() }
        }

        private fun pending(context: Context, key: String, spec: ReminderSpec?): PendingIntent? {
            val intent = Intent(context, ReminderReceiver::class.java).setAction("com.wiqo.android.REMINDER")
                .setData(android.net.Uri.parse("wiqo-reminder://local/$key"))
            spec?.let { intent.putExtra("spec", it.encode()) }
            return PendingIntent.getBroadcast(context, key.hashCode(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        internal fun onAlarm(context: Context, encoded: String?) {
            val spec = ReminderSpec.decode(encoded) ?: return
            val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            if (spec.key !in prefs.getStringSet(INSTALLED, emptySet()).orEmpty()) return
            if (canDeliver(context)) {
                runCatching {
                    val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    manager.createNotificationChannel(NotificationChannel(CHANNEL, "Wiqo hatırlatmaları", NotificationManager.IMPORTANCE_DEFAULT))
                    val open = PendingIntent.getActivity(context, spec.automationId,
                        Intent(context, MainActivity::class.java).setAction("OPEN_WIQO")
                            .putExtra("route", "activity").putExtra("automationId", spec.automationId.toString()),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    val notification = NotificationCompat.Builder(context, CHANNEL)
                        .setSmallIcon(R.mipmap.ic_launcher).setContentTitle(spec.title).setContentText(spec.body)
                        .setStyle(NotificationCompat.BigTextStyle().bigText(spec.body))
                        .setContentIntent(open).setAutoCancel(true).build()
                    NotificationManagerCompat.from(context).notify(spec.key.hashCode(), notification)
                }
            }
            if (spec.at == null) install(context, spec)
            else prefs.edit().putStringSet(INSTALLED, prefs.getStringSet(INSTALLED, emptySet()).orEmpty() - spec.key).apply()
        }

        internal fun restore(context: Context) {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            if (!canDeliver(context)) return
            preferences.getStringSet(RECORDS, emptySet()).orEmpty().forEach { raw ->
                ReminderSpec.decode(raw)?.let { spec -> if (spec.at == null || spec.at > System.currentTimeMillis()) install(context, spec) }
            }
        }
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        LocalReminderCoordinator.onAlarm(context, intent.getStringExtra("spec"))
    }
}

class ReminderRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_TIMEZONE_CHANGED,
                Intent.ACTION_TIME_CHANGED, Intent.ACTION_MY_PACKAGE_REPLACED)) LocalReminderCoordinator.restore(context)
    }
}

private data class ReminderSpec(
    val key: String, val automationId: Int, val hash: String, val title: String, val body: String,
    val hour: Int?, val minute: Int?, val weekday: Int?, val timezone: String?, val at: Long?,
) {
    fun nextEpochMillis(): Long? {
        at?.let { return it.takeIf { value -> value > System.currentTimeMillis() + 1_000 } }
        val zone = runCatching { ZoneId.of(timezone ?: return null) }.getOrNull() ?: return null
        var day = ZonedDateTime.now(zone).toLocalDate()
        repeat(8) {
            val local = LocalDateTime.of(day, java.time.LocalTime.of(hour ?: return null, minute ?: return null))
            val candidate = local.atZone(zone)
            val cronDay = candidate.dayOfWeek.value % 7
            if ((weekday == null || weekday == cronDay) && candidate.toInstant().toEpochMilli() > System.currentTimeMillis() + 1_000)
                return candidate.toInstant().toEpochMilli()
            day = day.plusDays(1)
        }
        return null
    }

    fun encode(): String = buildJsonObject {
        put("key", key); put("automationId", automationId); put("hash", hash); put("title", title); put("body", body)
        hour?.let { put("hour", it) }; minute?.let { put("minute", it) }
        weekday?.let { put("weekday", it) }; timezone?.let { put("timezone", it) }; at?.let { put("at", it) }
    }.toString()

    companion object {
        fun decode(value: String?): ReminderSpec? {
            val row = runCatching { kotlinx.serialization.json.Json.parseToJsonElement(value ?: return null) as? JsonObject }.getOrNull() ?: return null
            return ReminderSpec(row.string("key") ?: return null, row.integer("automationId") ?: return null,
                row.string("hash").orEmpty(), row.string("title") ?: return null, row.string("body") ?: return null,
                row.integer("hour"), row.integer("minute"), row.integer("weekday"), row.string("timezone"),
                (row["at"] as? JsonPrimitive)?.contentOrNull?.toLongOrNull())
        }
    }
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.integer(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
