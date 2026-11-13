package com.kurubyinteractive.aimanga.data

import android.content.Context
import com.kurubyinteractive.aimanga.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import org.json.JSONObject
import uniffi.koharu_core.AppConfig
import uniffi.koharu_core.ConfigValidators
import uniffi.koharu_core.bundledAppConfig
import uniffi.koharu_core.fetchAppConfig
import uniffi.koharu_core.parseAppConfig
import java.io.File

enum class ConfigStatus { BUNDLED, SAVED, CHECKING, UNCHANGED, UPDATED, FAILED }

data class ConfigState(
    val config: AppConfig,
    val status: ConfigStatus,
    val etag: String?,
    val lastModified: String?,
)

/**
 * Remote app-config.json for this build's environment and version
 * (`env/<environment>/<versionName>/configs/app-config.json`). The validated
 * document and its S3 validators are saved in one file and replaced by an
 * atomic rename; the bundled iPad JSON is the offline seed.
 */
class ConfigStore(context: Context) {
    val environment: String = BuildConfig.KOHARU_ENVIRONMENT
    val version: String = BuildConfig.VERSION_NAME
    private val file = File(context.filesDir, "RemoteConfiguration/$environment/$version/active.json")
    private val state = MutableStateFlow(load())
    val current: StateFlow<ConfigState> = state.asStateFlow()

    private fun load(): ConfigState = runCatching {
        val saved = JSONObject(file.readText())
        ConfigState(
            config = parseAppConfig(saved.getString("body")),
            status = ConfigStatus.SAVED,
            etag = saved.getString("etag"),
            lastModified = saved.getString("lastModified"),
        )
    }.getOrElse {
        ConfigState(parseAppConfig(bundledAppConfig()), ConfigStatus.BUNDLED, null, null)
    }

    /** Checks S3; a failure keeps the last valid configuration active. */
    suspend fun refresh() {
        val before = state.value
        state.update { it.copy(status = ConfigStatus.CHECKING) }
        try {
            val validators = before.etag?.let { ConfigValidators(it, before.lastModified.orEmpty()) }
            val remote = fetchAppConfig(environment, version, validators)
            if (remote == null) {
                state.value = before.copy(status = ConfigStatus.UNCHANGED)
                return
            }
            val config = parseAppConfig(remote.body)
            withContext(Dispatchers.IO) {
                file.parentFile?.mkdirs()
                val temporary = File(file.parentFile, "active.json.tmp")
                temporary.writeText(
                    JSONObject()
                        .put("etag", remote.etag)
                        .put("lastModified", remote.lastModified)
                        .put("body", remote.body)
                        .toString(),
                )
                check(temporary.renameTo(file)) { "Could not save configuration" }
            }
            state.value = ConfigState(config, ConfigStatus.UPDATED, remote.etag, remote.lastModified)
        } catch (error: CancellationException) {
            state.value = before
            throw error
        } catch (_: Throwable) {
            state.value = before.copy(status = ConfigStatus.FAILED)
        }
    }
}
