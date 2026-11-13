package com.kurubyinteractive.aimanga.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.edit
import uniffi.koharu_core.Provider
import uniffi.koharu_core.SeriesContext
import uniffi.koharu_core.TranslatorConfig
import uniffi.koharu_core.targetLanguages
import java.security.KeyStore
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class Preferences(
    val provider: Provider,
    val model: String,
    val server: String,
    val target: String,
    val instructions: String,
    val batchSize: Int,
    val dynamicColor: Boolean,
    val theme: ThemeMode,
    val reading: ReadingMode,
    /** Chapter and manga lists as rows with full titles instead of cover grids. */
    val listLayout: Boolean = false,
)

enum class ThemeMode { SYSTEM, LIGHT, DARK }

/** Reader layout (iPad `ReadingMode`): right-to-left page swipes or one vertical strip. */
enum class ReadingMode { HORIZONTAL, VERTICAL }

/**
 * Plain preferences in SharedPreferences. API keys are encrypted with an
 * Android Keystore AES-GCM key that never leaves the device's keystore.
 */
class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** [defaultProvider] comes from app-config.json and applies until the user picks one. */
    fun load(defaultProvider: Provider): Preferences {
        val provider = prefs.getString("provider", null)
            ?.let { runCatching { Provider.valueOf(it) }.getOrNull() } ?: defaultProvider
        return Preferences(
            provider = provider,
            model = prefs.getString("model.${provider.name}", "").orEmpty(),
            server = prefs.getString("server", "http://192.168.1.2:1234").orEmpty(),
            target = prefs.getString("target", null) ?: defaultTarget(),
            instructions = prefs.getString("instructions", "").orEmpty(),
            batchSize = prefs.getInt("batchSize", 40),
            // Off by default so the app keeps its pink brand palette.
            dynamicColor = prefs.getBoolean("dynamicColor", false),
            theme = prefs.getString("theme", null)
                ?.let { runCatching { ThemeMode.valueOf(it) }.getOrNull() } ?: ThemeMode.SYSTEM,
            reading = prefs.getString("reading", null)
                ?.let { runCatching { ReadingMode.valueOf(it) }.getOrNull() } ?: ReadingMode.VERTICAL,
            listLayout = prefs.getBoolean("listLayout", false),
        )
    }

    fun modelFor(provider: Provider) = prefs.getString("model.${provider.name}", "").orEmpty()

    fun save(p: Preferences) = prefs.edit {
        putString("provider", p.provider.name)
        putString("model.${p.provider.name}", p.model)
        putString("server", p.server)
        putString("target", p.target)
        putString("instructions", p.instructions)
        putInt("batchSize", p.batchSize)
        putBoolean("dynamicColor", p.dynamicColor)
        putString("theme", p.theme.name)
        putString("reading", p.reading.name)
        putBoolean("listLayout", p.listLayout)
    }

    fun apiKey(provider: Provider): String = secret("key.${provider.name}")

    fun setApiKey(provider: Provider, key: String) = setSecret("key.${provider.name}", key.trim())

    /** A value sealed with the Keystore AES-GCM key; empty when absent or unreadable. */
    fun secret(name: String): String {
        val stored = prefs.getString(name, null) ?: return ""
        return runCatching {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, bytes, 0, IV_SIZE))
            String(cipher.doFinal(bytes, IV_SIZE, bytes.size - IV_SIZE), Charsets.UTF_8)
        }.getOrDefault("")
    }

    fun setSecret(name: String, value: String) = prefs.edit {
        if (value.isEmpty()) {
            remove(name)
            return@edit
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        putString(name, Base64.encodeToString(sealed, Base64.NO_WRAP))
    }

    fun config(p: Preferences, series: SeriesContext? = null, rerun: Boolean = false, enhanced: Boolean = false) = TranslatorConfig(
        provider = p.provider,
        apiKey = apiKey(p.provider),
        model = p.model,
        server = p.server,
        targetLanguage = p.target,
        instructions = p.instructions,
        batchSize = p.batchSize.toUInt(),
        series = series,
        rerun = rerun,
        enhanced = enhanced,
    )

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).apply {
            init(
                KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
        }.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "koharu-api-keys"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12

        /** First target matching the device language, preferring its region. */
        fun defaultTarget(): String {
            val locale = Locale.getDefault()
            val tags = targetLanguages().map { it.tag }
            return tags.firstOrNull { it.equals(locale.toLanguageTag(), ignoreCase = true) }
                ?: tags.firstOrNull { it.substringBefore('-') == locale.language }
                ?: "en-US"
        }
    }
}
