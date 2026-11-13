package com.kurubyinteractive.aimanga.data

import android.content.Context
import android.net.Uri
import android.os.Bundle
import com.google.firebase.FirebaseApp
import com.google.firebase.analytics.FirebaseAnalytics
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.google.firebase.remoteconfig.ConfigUpdate
import com.google.firebase.remoteconfig.ConfigUpdateListener
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import com.google.firebase.remoteconfig.FirebaseRemoteConfigException
import com.google.firebase.remoteconfig.remoteConfigSettings
import com.kurubyinteractive.aimanga.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** A store version the installed app must update to before it can be used. */
data class AppUpdate(val version: String, val storeUrl: String)

/**
 * Firebase services (port of iPad `CloudServices`): analytics limited to screen
 * names with advertising consent denied, Crashlytics in release builds, and the
 * Remote Config update gate shared with iPad (`game_version`,
 * `force_update_enabled`) plus Android's own store link (`google_play_url`).
 */
class CloudServices(private val context: Context) {
    private val available = FirebaseApp.getApps(context).isNotEmpty()
    private val update = MutableStateFlow<AppUpdate?>(null)
    val requiredUpdate: StateFlow<AppUpdate?> = update.asStateFlow()
    private var remote: FirebaseRemoteConfig? = null

    fun configure() {
        if (!available || remote != null) return
        val analytics = FirebaseAnalytics.getInstance(context)
        // Firebase is for app analytics, not cross-app advertising profiles.
        analytics.setConsent(
            mapOf(
                FirebaseAnalytics.ConsentType.AD_STORAGE to FirebaseAnalytics.ConsentStatus.DENIED,
                FirebaseAnalytics.ConsentType.AD_USER_DATA to FirebaseAnalytics.ConsentStatus.DENIED,
                FirebaseAnalytics.ConsentType.AD_PERSONALIZATION to FirebaseAnalytics.ConsentStatus.DENIED,
            ),
        )
        analytics.setAnalyticsCollectionEnabled(true)
        FirebaseCrashlytics.getInstance().isCrashlyticsCollectionEnabled = !BuildConfig.DEBUG

        val config = FirebaseRemoteConfig.getInstance()
        config.setConfigSettingsAsync(remoteConfigSettings {
            minimumFetchIntervalInSeconds = 3600
            fetchTimeoutInSeconds = 10
        })
        config.setDefaultsAsync(mapOf("game_version" to "1.0.0", "force_update_enabled" to false, "google_play_url" to ""))
        remote = config
        // SDK persistence keeps the last activated policy across offline launches.
        config.activate().addOnCompleteListener { apply() }
        config.fetchAndActivate().addOnCompleteListener { apply() }
        config.addOnConfigUpdateListener(object : ConfigUpdateListener {
            override fun onUpdate(configUpdate: ConfigUpdate) {
                config.activate().addOnCompleteListener { apply() }
            }

            override fun onError(error: FirebaseRemoteConfigException) {}
        })
    }

    /** Fetches the policy now, ignoring the fetch interval ("Check again"). */
    fun refresh() {
        val config = remote ?: return
        config.fetch(0).addOnSuccessListener { config.activate().addOnCompleteListener { apply() } }
    }

    /** Screen names only; manga text, URLs, prompts and credentials never enter telemetry. */
    fun trackScreen(name: String) {
        if (!available) return
        FirebaseAnalytics.getInstance(context).logEvent(
            FirebaseAnalytics.Event.SCREEN_VIEW,
            Bundle().apply { putString(FirebaseAnalytics.Param.SCREEN_NAME, name) },
        )
    }

    private fun apply() {
        val config = remote ?: return
        update.value = required(
            current = BuildConfig.VERSION_NAME,
            minimum = config.getString("game_version"),
            enabled = config.getBoolean("force_update_enabled"),
            store = config.getString("google_play_url"),
        )
    }

    private fun required(current: String, minimum: String, enabled: Boolean, store: String): AppUpdate? {
        fun parts(value: String): List<Int>? {
            val pieces = value.split('.')
            if (pieces.size !in 1..3 || pieces.any { p -> p.isEmpty() || !p.all(Char::isDigit) }) return null
            return pieces.map { it.toInt() } + List(3 - pieces.size) { 0 }
        }
        val installed = parts(current) ?: return null
        val target = parts(minimum) ?: return null
        val older = installed.zip(target).firstOrNull { (a, b) -> a != b }?.let { (a, b) -> a < b } ?: false
        // Only this app's own Google Play listing is accepted as the update link.
        val url = runCatching { Uri.parse(store) }.getOrNull()
        val play = url != null && url.scheme == "https" && url.host == "play.google.com" && url.path == "/store/apps/details" &&
            url.getQueryParameter("id") == context.packageName && url.userInfo == null && url.port == -1
        return if (enabled && older && play) AppUpdate(minimum, store) else null
    }
}
