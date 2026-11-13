package com.kurubyinteractive.aimanga

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.kurubyinteractive.aimanga.data.AccountState
import com.kurubyinteractive.aimanga.data.BackendAccount
import com.kurubyinteractive.aimanga.data.Chapter
import com.kurubyinteractive.aimanga.data.ConfigState
import com.kurubyinteractive.aimanga.data.ConfigStore
import com.kurubyinteractive.aimanga.data.Library
import com.kurubyinteractive.aimanga.data.Preferences
import com.kurubyinteractive.aimanga.data.Project
import com.kurubyinteractive.aimanga.data.SettingsStore
import com.kurubyinteractive.aimanga.pipeline.ChapterTranslator
import com.kurubyinteractive.aimanga.pipeline.Progress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import uniffi.koharu_core.ModelInfo
import uniffi.koharu_core.AppConfig
import uniffi.koharu_core.DownloadProgress
import uniffi.koharu_core.SeriesContext
import uniffi.koharu_core.SourceChapter
import uniffi.koharu_core.downloadPages
import uniffi.koharu_core.fetchSeries
import uniffi.koharu_core.Provider
import uniffi.koharu_core.ProviderInfo
import uniffi.koharu_core.listModels
import uniffi.koharu_core.providers

/** The saved provider is disabled by the active app-config.json. */
class ProviderDisabledException : IllegalStateException()

/**
 * Android providers app-config.json enables, in the native catalog order.
 * Backend API also needs an active server and this build's backend identity.
 */
fun AppConfig.enabledProviders(backendAvailable: Boolean): List<ProviderInfo> {
    val enabled = providers.filter { it.enable }.map { it.id }.toSet()
    return providers().filter { it.id in enabled && (!it.needsAccount || (serverActive && backendAvailable)) }
}

/**
 * The configured default when Android implements it; otherwise (for example
 * the Backend API default) the first enabled provider this app supports.
 */
private fun AppConfig.defaultProvider(backendAvailable: Boolean): Provider {
    val enabled = enabledProviders(backendAvailable)
    return (enabled.firstOrNull { it.id == defaultProvider } ?: enabled.firstOrNull())?.provider ?: Provider.GEMINI
}

/** Pages of a Rawkuma chapter being downloaded. */
data class SourceDownload(val done: Int, val total: Int)

/** A chapter translation in progress; one runs at a time. */
data class Run(val chapterId: String, val progress: Progress?)

sealed interface ModelState {
    data object Idle : ModelState
    data object Loading : ModelState
    data class Loaded(val models: List<ModelInfo>) : ModelState
    data class Failed(val error: Throwable) : ModelState
}

class AppViewModel(application: Application) : AndroidViewModel(application) {
    val library = Library(application)
    private val settings = SettingsStore(application)
    private val translator = ChapterTranslator(library)
    private val configStore = ConfigStore(application)
    val config: StateFlow<ConfigState> = configStore.current
    val configEnvironment: String get() = configStore.environment
    val configVersion: String get() = configStore.version
    val account = BackendAccount(application, settings)
    val accountState: StateFlow<AccountState> = account.current
    val enabledProviders: StateFlow<List<ProviderInfo>> = combine(configStore.current, account.current) { config, state ->
        config.config.enabledProviders(state.available)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, configStore.current.value.config.enabledProviders(account.hasIdentity))
    private var configJob: Job? = null
    private var refreshDeferred = false

    private val prefsState = MutableStateFlow(settings.load(configStore.current.value.config.defaultProvider(account.hasIdentity)))

    init {
        viewModelScope.launch {
            configStore.current.map { it.config.serverActive to it.config.serverEndpoint }.distinctUntilChanged().collect { (active, endpoint) ->
                runCatching { account.configure(active, endpoint) }
            }
        }
    }

    fun signInGuest() = accountAction { account.signInGuest() }
    fun signInEmail(email: String, password: String) = accountAction { account.signInEmail(email, password) }
    fun signOut() = accountAction { account.signOut() }
    fun claimDaily() = accountAction { account.claimDaily() }
    fun refreshCredits() = accountAction { account.refreshCredits() }

    private fun accountAction(action: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                action()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                errorChannel.send(error)
            }
        }
    }
    val prefs: StateFlow<Preferences> = prefsState.asStateFlow()

    private val keyState = MutableStateFlow(settings.apiKey(prefsState.value.provider))
    val apiKey: StateFlow<String> = keyState.asStateFlow()

    private val modelState = MutableStateFlow<ModelState>(ModelState.Idle)
    val models: StateFlow<ModelState> = modelState.asStateFlow()

    private val runState = MutableStateFlow<Run?>(null)
    val run: StateFlow<Run?> = runState.asStateFlow()
    private var job: Job? = null

    private val downloadState = MutableStateFlow<SourceDownload?>(null)
    val download: StateFlow<SourceDownload?> = downloadState.asStateFlow()
    private var downloadJob: Job? = null

    private val errorChannel = Channel<Throwable>(Channel.BUFFERED)
    val errors = errorChannel.receiveAsFlow()

    /** Checks for a newer app-config.json; deferred while a chapter is translating. */
    fun refreshConfig() {
        if (runState.value != null) {
            refreshDeferred = true
            return
        }
        if (configJob?.isActive == true) return
        configJob = viewModelScope.launch { configStore.refresh() }
    }

    fun update(transform: (Preferences) -> Preferences) {
        val next = transform(prefsState.value)
        prefsState.value = next
        settings.save(next)
    }

    fun selectProvider(provider: Provider) {
        if (provider == prefsState.value.provider) return
        update { it.copy(provider = provider, model = settings.modelFor(provider)) }
        keyState.value = settings.apiKey(provider)
        modelState.value = ModelState.Idle
    }

    fun setApiKey(key: String) {
        keyState.value = key
        settings.setApiKey(prefsState.value.provider, key)
        modelState.value = ModelState.Idle
    }

    /** Validates the key with the provider and lists structured-output models. */
    fun loadModels() {
        modelState.value = ModelState.Loading
        viewModelScope.launch {
            modelState.value = try {
                val models = listModels(settings.config(prefsState.value))
                if (prefsState.value.model.isEmpty()) update { it.copy(model = models.first().id) }
                ModelState.Loaded(models)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                ModelState.Failed(error)
            }
        }
    }

    /** [uris] are in page order; system-picker results are ordered by file name first. */
    fun import(title: String, uris: List<Uri>, sortByName: Boolean = false, projectId: String? = null) {
        viewModelScope.launch {
            try {
                library.import(title, if (sortByName) sortedByName(uris) else uris, projectId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                errorChannel.send(error)
            }
        }
    }

    fun saveProject(project: Project) = library.saveProject(project)
    fun deleteProject(id: String) = library.deleteProject(id)
    fun move(chapter: Chapter, projectId: String?) = library.move(chapter, projectId)

    fun delete(chapter: Chapter) {
        if (runState.value?.chapterId == chapter.id) cancel()
        library.delete(chapter)
    }

    /**
     * Translates [chapter] (iPad `run`). [force] translates saved pages again
     * (a rerun), [page] limits it to one page, and [enhanced] uses Backend API's
     * translate-then-review pass whatever provider is selected. A chapter saved
     * in another target language is copied first, keeping its translation; the
     * copy is reported through [onChapter] so the reader can show it.
     */
    fun translate(
        chapter: Chapter,
        force: Boolean = false,
        page: Int? = null,
        enhanced: Boolean = false,
        onChapter: (Chapter) -> Unit = {},
    ) {
        if (job?.isActive == true) return
        val prefs = prefsState.value.let { if (enhanced) it.copy(provider = Provider.BACKEND) else it }
        if (enabledProviders.value.none { it.provider == prefs.provider }) {
            errorChannel.trySend(ProviderDisabledException())
            return
        }
        val backend = prefs.provider == Provider.BACKEND
        if (backend && accountState.value.user == null) {
            errorChannel.trySend(uniffi.koharu_core.BackendException.SignedOut())
            return
        }
        runState.value = Run(chapter.id, null)
        job = viewModelScope.launch {
            try {
                var target = chapter
                if (chapter.target != null && chapter.target != prefs.target && chapter.translatedPages > 0) {
                    target = library.copyForTarget(chapter, prefs.target)
                    runState.value = Run(target.id, null)
                    onChapter(target)
                }
                val rerun = force && target.translatedPages > 0
                val config = settings.config(prefs, target.series, rerun = rerun && !enhanced, enhanced = enhanced)
                translator.run(target, config, account.client.takeIf { backend }, force = force || enhanced, only = page) { progress ->
                    runState.value = Run(target.id, progress)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                errorChannel.send(error)
            } finally {
                if (backend) {
                    account.afterCall()
                    runCatching { account.refreshCredits() }
                }
                runState.value = null
                if (refreshDeferred) {
                    refreshDeferred = false
                    refreshConfig()
                }
            }
        }
    }

    fun cancel() {
        job?.cancel()
    }

    /**
     * Downloads a Rawkuma chapter into a new library chapter, then opens it
     * ([onReady]) and starts translating it with the series as reference data.
     */
    fun importSource(chapter: SourceChapter, series: SeriesContext?, onReady: (Chapter) -> Unit) {
        val site = config.value.config.rawkumaUrl ?: return
        if (downloadJob?.isActive == true || runState.value != null) return
        downloadState.value = SourceDownload(0, chapter.images.size)
        downloadJob = viewModelScope.launch {
            try {
                // Reference data only: a series page that cannot be read does not block translation.
                val context = series ?: runCatching { fetchSeries(site, chapter.url) }.getOrNull()
                val title = chapter.title.substringBefore(" - Rawkuma").substringBefore(" | Rawkuma").trim()
                    .ifEmpty { context?.title.orEmpty() }
                val created = library.create(title, chapter.url, context) { dir ->
                    downloadPages(site, chapter, dir.path, object : DownloadProgress {
                        override fun onPage(done: UInt, total: UInt) {
                            downloadState.value = SourceDownload(done.toInt(), total.toInt())
                        }
                    })
                }
                downloadState.value = null
                onReady(created)
                translate(created)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                errorChannel.send(error)
            } finally {
                downloadState.value = null
            }
        }
    }

    fun cancelDownload() {
        downloadJob?.cancel()
    }

    /** Files picked from a folder are paged by natural name order (2 before 10). */
    private fun sortedByName(uris: List<Uri>): List<Uri> {
        val resolver = getApplication<Application>().contentResolver
        val names = uris.associateWith { uri ->
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            } ?: uri.lastPathSegment.orEmpty()
        }
        return uris.sortedWith { a, b -> naturalCompare(names.getValue(a), names.getValue(b)) }
    }
}

private val chunk = Regex("\\d+|\\D+")

/** File-name order where digit runs compare as numbers (page 2 before page 10). */
fun naturalCompare(a: String, b: String): Int {
    val x = chunk.findAll(a.lowercase()).map { it.value }.toList()
    val y = chunk.findAll(b.lowercase()).map { it.value }.toList()
    for ((p, q) in x.zip(y)) {
        val order = if (p[0].isDigit() && q[0].isDigit()) p.toBigInteger().compareTo(q.toBigInteger()) else p.compareTo(q)
        if (order != 0) return order
    }
    return x.size.compareTo(y.size)
}
