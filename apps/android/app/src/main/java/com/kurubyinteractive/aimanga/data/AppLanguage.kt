package com.kurubyinteractive.aimanga.data

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.LocaleList
import androidx.core.content.edit
import java.util.Locale

/**
 * Interface languages of iPad `AppLanguage`. Each name is the language's own
 * name in every locale; [SYSTEM] follows the device's preferred languages.
 */
enum class AppLanguage(val tag: String, val nativeName: String) {
    SYSTEM("", ""),
    ENGLISH_US("en-US", "English (US)"),
    ENGLISH_UK("en-GB", "English (UK)"),
    FRENCH("fr", "Français"),
    ARABIC("ar", "العربية"),
    SPANISH("es", "Español"),
    PORTUGUESE("pt", "Português"),
    GERMAN("de", "Deutsch"),
    KOREAN("ko", "한국어"),
    JAPANESE("ja", "日本語"),
    TRADITIONAL_CHINESE("zh-Hant", "繁體中文"),
    SIMPLIFIED_CHINESE("zh-Hans", "简体中文"),
    VIETNAMESE("vi", "Tiếng Việt");

    companion object {
        private const val KEY = "appLanguage"

        fun current(context: Context): AppLanguage {
            val saved = prefs(context).getString(KEY, null)
            return entries.firstOrNull { it.name == saved } ?: SYSTEM
        }

        /**
         * Android 13+ keeps the per-app language itself (also editable in
         * system settings) and recreates the activity; older versions apply it
         * through [wrap] on the next activity creation.
         */
        fun apply(context: Context, language: AppLanguage) {
            prefs(context).edit { putString(KEY, language.name) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.getSystemService(LocaleManager::class.java).applicationLocales =
                    if (language == SYSTEM) LocaleList.getEmptyLocaleList() else LocaleList.forLanguageTags(language.tag)
            }
        }

        /** Base context for Android 12 and older, where the platform has no per-app language. */
        fun wrap(base: Context): Context {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return base
            val language = current(base)
            if (language == SYSTEM) return base
            val locale = Locale.forLanguageTag(language.tag)
            Locale.setDefault(locale)
            val configuration = Configuration(base.resources.configuration).apply {
                setLocale(locale)
                setLayoutDirection(locale)
            }
            return base.createConfigurationContext(configuration)
        }

        private fun prefs(context: Context) = context.getSharedPreferences("interface", Context.MODE_PRIVATE)
    }
}
