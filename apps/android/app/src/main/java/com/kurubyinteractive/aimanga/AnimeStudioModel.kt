package com.kurubyinteractive.aimanga

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.os.StatFs
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.kurubyinteractive.aimanga.data.AnimeImage
import com.kurubyinteractive.aimanga.data.AnimeStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import uniffi.koharu_core.AnimaConfig
import uniffi.koharu_core.AnimaJob
import uniffi.koharu_core.AnimaPaths
import uniffi.koharu_core.ModelDownloadProgress
import uniffi.koharu_core.animaAvailable
import uniffi.koharu_core.animaConfig
import uniffi.koharu_core.animaFileReady
import uniffi.koharu_core.downloadAnimaFile
import java.io.File
import uniffi.koharu_core.animeUpscalers
import uniffi.koharu_core.AnimeUpscaler
import java.util.UUID
import uniffi.koharu_core.providerCreditId
import uniffi.koharu_core.animePrompt
import uniffi.koharu_core.TranslatorConfig
import uniffi.koharu_core.Provider
import uniffi.koharu_core.PromptOperation
import uniffi.koharu_core.BackendException
import uniffi.koharu_core.BackendClient
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CompletableDeferred
import com.kurubyinteractive.aimanga.data.BackendAccount
import kotlin.random.Random

/** Why Anime Studio cannot run here. */
enum class AnimeBlock {
    UNSUPPORTED_ABI, MEMORY,
    /** DeepL translates text only; prompts need a language model. */
    PROVIDER,
    /** Upscaling is on but its model is not downloaded. */
    UPSCALER,
    /** Prompt assistance and generation use account credits. */
    SIGN_IN,
    /** half/full-safe: the server review rejected the prompt. */
    RESTRICTED,
    /** half/full-safe: the review service could not be reached. */
    REVIEW_UNAVAILABLE,
    /** half/full-safe: the user declined prompt review. */
    CONSENT,
}

class AnimeBlockedException(val reason: AnimeBlock) : IllegalStateException()

/** The device lacks free space for a model file; sizes in bytes. */
class AnimeStorageException(val file: String, val needed: Long, val free: Long) : IllegalStateException()

/**
 * Download state of the Anima components (iPad lists diffusion model, text
 * encoder and VAE separately). `parts` maps each role to whether its file is
 * on disk and verified; `active` is the role downloading now, with its bytes.
 */
data class AnimaModelState(
    val parts: Map<String, Boolean>,
    val downloading: Boolean = false,
    val active: String? = null,
    val done: Long = 0,
    val total: Long = 0,
) {
    val ready: Boolean get() = parts.isNotEmpty() && parts.values.all { it }
}

/** 0 reviewing the prompt, 1 loading the model, 2 sampling (step/steps), 3 saving, 4 upscaling. */
data class Generation(val phase: Int, val step: Int = 0, val steps: Int = 0)

/**
 * Optional ×4 upscaling after generation (iPad `AnimeUpscaler`): on/off, the
 * chosen RealESRGAN model, which files are on disk, and a running download.
 */
data class UpscaleState(
    val enabled: Boolean,
    val selected: String,
    val ready: Map<String, Boolean>,
    val downloading: String? = null,
    val done: Long = 0,
    val total: Long = 0,
) {
    val selectedReady: Boolean get() = ready[selected] == true
}

/** A provider-written English prompt awaiting review (iPad `AnimePromptSuggestion`). */
data class PromptSuggestion(val original: String, val prompt: String, val character: String, val provider: String)

/**
 * Anime Studio (port of the iPad `MangaLibrary` anime flow): download the
 * Anima components from anima-config.json, then generate locally.
 */
class AnimeStudioModel(application: Application) : AndroidViewModel(application) {
    val store = AnimeStore(application)
    val config: AnimaConfig? = runCatching { animaConfig() }.getOrNull()
    private val modelDir = File(application.filesDir, "models/${config?.id ?: "anima"}")

    private val modelState = MutableStateFlow(AnimaModelState(parts()))
    val model: StateFlow<AnimaModelState> = modelState.asStateFlow()
    private var downloadJob: Job? = null
    @Volatile private var stopDownload = false

    private val generationState = MutableStateFlow<Generation?>(null)
    val generation: StateFlow<Generation?> = generationState.asStateFlow()
    private var generateJob: Job? = null
    private var animaJob: AnimaJob? = null

    private val prefs = application.getSharedPreferences("anime", Context.MODE_PRIVATE)
    val upscalers: List<AnimeUpscaler> = animeUpscalers()
    private val upscalerDir = File(application.filesDir, "models/upscalers")
    private val upscaleState = MutableStateFlow(
        UpscaleState(
            enabled = prefs.getBoolean("upscale", false),
            selected = prefs.getString("upscaler", null)?.takeIf { id -> upscalers.any { it.id == id } } ?: upscalers.first().id,
            ready = upscalerParts(),
        ),
    )
    val upscale: StateFlow<UpscaleState> = upscaleState.asStateFlow()
    private val suggestionState = MutableStateFlow<PromptSuggestion?>(null)
    val suggestion: StateFlow<PromptSuggestion?> = suggestionState.asStateFlow()
    private val assistingState = MutableStateFlow(false)
    val assisting: StateFlow<Boolean> = assistingState.asStateFlow()
    private var assistJob: Job? = null
    private val consentState = MutableStateFlow(false)
    /** half/full-safe asks once per account before prompt text goes to the review service. */
    val needsConsent: StateFlow<Boolean> = consentState.asStateFlow()
    private var consentWaiter: CompletableDeferred<Boolean>? = null

    private val errorChannel = Channel<Throwable>(Channel.BUFFERED)
    val errors = errorChannel.receiveAsFlow()

    val totalBytes: Long get() = config?.components?.sumOf { it.file.bytes.toLong() } ?: 0

    /** The reason generation is unavailable on this device, if any (before content review). */
    val deviceBlock: AnimeBlock? = when {
        !animaAvailable() -> AnimeBlock.UNSUPPORTED_ABI
        !enoughMemory(application) -> AnimeBlock.MEMORY
        else -> null
    }

    private fun upscalerParts(): Map<String, Boolean> =
        animeUpscalers().associate { it.id to animaFileReady(it.file, File(getApplication<Application>().filesDir, "models/upscalers").path) }

    fun setUpscale(enabled: Boolean) {
        prefs.edit().putBoolean("upscale", enabled).apply()
        upscaleState.value = upscaleState.value.copy(enabled = enabled)
    }

    fun selectUpscaler(id: String) {
        if (upscalers.none { it.id == id }) return
        prefs.edit().putString("upscaler", id).apply()
        upscaleState.value = upscaleState.value.copy(selected = id)
    }

    /** Downloads the selected upscaler (resumable, SHA-256 checked like the Anima files). */
    fun downloadUpscaler() {
        val upscaler = upscalers.firstOrNull { it.id == upscaleState.value.selected } ?: return
        if (downloadJob?.isActive == true) return
        stopDownload = false
        downloadJob = viewModelScope.launch {
            try {
                upscalerDir.mkdirs()
                val partial = File(upscalerDir, upscaler.file.path + ".part").takeIf { it.exists() }?.length() ?: 0L
                val needed = upscaler.file.bytes.toLong() - partial + STORAGE_MARGIN
                val free = StatFs(upscalerDir.path).availableBytes
                if (free < needed) throw AnimeStorageException(upscaler.file.path, needed, free)
                upscaleState.value = upscaleState.value.copy(downloading = upscaler.id, done = 0, total = upscaler.file.bytes.toLong())
                downloadAnimaFile(upscaler.file, upscalerDir.path, object : ModelDownloadProgress {
                    override fun onBytes(done: ULong, total: ULong) {
                        upscaleState.value = upscaleState.value.copy(done = done.toLong(), total = total.toLong())
                    }
                    override fun isCancelled() = stopDownload
                })
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (!stopDownload) errorChannel.send(error)
            } finally {
                upscaleState.value = upscaleState.value.copy(downloading = null, ready = upscalerParts())
            }
        }
    }

    fun deleteUpscalers() {
        if (downloadJob?.isActive == true || generationState.value != null) return
        upscalerDir.deleteRecursively()
        upscaleState.value = upscaleState.value.copy(ready = upscalerParts())
    }

    private fun parts(): Map<String, Boolean> =
        config?.components?.associate { it.role to animaFileReady(it.file, modelDir.path) }.orEmpty()

    /** Downloads one component (`diffusion`, `textEncoder`, `vae`), or every missing one when [role] is null. */
    fun download(role: String? = null) {
        val config = config ?: return
        if (downloadJob?.isActive == true) return
        stopDownload = false
        downloadJob = viewModelScope.launch {
            try {
                for (component in config.components.filter { role == null || it.role == role }) {
                    val file = component.file
                    if (animaFileReady(file, modelDir.path)) continue
                    // Check space up front: a full disk otherwise only shows up as a failed write.
                    modelDir.mkdirs()
                    val partial = File(modelDir, file.path + ".part").takeIf { it.exists() }?.length() ?: 0L
                    val needed = file.bytes.toLong() - partial + STORAGE_MARGIN
                    val free = StatFs(modelDir.path).availableBytes
                    if (free < needed) throw AnimeStorageException(file.path, needed, free)
                    modelState.value = AnimaModelState(parts(), true, component.role, 0, file.bytes.toLong())
                    downloadAnimaFile(file, modelDir.path, object : ModelDownloadProgress {
                        override fun onBytes(done: ULong, total: ULong) {
                            modelState.value = modelState.value.copy(done = done.toLong(), total = total.toLong())
                        }
                        override fun isCancelled() = stopDownload
                    })
                    modelState.value = AnimaModelState(parts(), true, null)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (!stopDownload) errorChannel.send(error)
            } finally {
                modelState.value = AnimaModelState(parts())
            }
        }
    }

    fun cancelDownload() {
        stopDownload = true
    }

    fun deleteModel() {
        if (downloadJob?.isActive == true || generationState.value != null) return
        modelDir.deleteRecursively()
        modelState.value = AnimaModelState(parts())
    }

    fun resolveConsent(allow: Boolean) {
        consentState.value = false
        consentWaiter?.complete(allow)
        consentWaiter = null
    }

    /**
     * Prompt review (iPad `ContentSafety.checkText`): half-safe and full-safe
     * send the text to Kuruby's `content_moderate`; none-safe skips it. Every
     * new action is reviewed again, without cached approvals.
     */
    private suspend fun review(account: BackendAccount, text: String, safe: Boolean) {
        if (!safe || text.isBlank()) return
        val user = account.current.value.user ?: throw AnimeBlockedException(AnimeBlock.SIGN_IN)
        val key = "promptSafetyConsent-v1:${user.id}"
        if (!prefs.getBoolean(key, false)) {
            val waiter = CompletableDeferred<Boolean>()
            consentWaiter = waiter
            consentState.value = true
            if (!waiter.await()) throw AnimeBlockedException(AnimeBlock.CONSENT)
            prefs.edit().putBoolean(key, true).apply()
        }
        val client = account.client ?: throw AnimeBlockedException(AnimeBlock.REVIEW_UNAVAILABLE)
        val allowed = try {
            client.moderate(text)
        } catch (error: BackendException) {
            throw AnimeBlockedException(AnimeBlock.REVIEW_UNAVAILABLE)
        } finally {
            account.afterCall()
        }
        if (!allowed) throw AnimeBlockedException(AnimeBlock.RESTRICTED)
    }

    private fun signedIn(account: BackendAccount): BackendClient =
        account.client?.takeIf { account.current.value.user != null } ?: throw AnimeBlockedException(AnimeBlock.SIGN_IN)

    /**
     * Prompt assistance with the provider selected in Settings (iPad
     * `assistAnimePrompt`): review the input, reserve `enhance` or
     * `generatePrompt` credits, ask the provider for an English Anima prompt,
     * review the result, then settle (Backend API settles on the server).
     */
    fun assist(operation: PromptOperation, description: String, account: BackendAccount, translator: TranslatorConfig, safe: Boolean) {
        if (assistJob?.isActive == true || generationState.value != null) return
        suggestionState.value = null
        assistJob = viewModelScope.launch {
            assistingState.value = true
            var client: BackendClient? = null
            var reservation: String? = null
            var succeeded = false
            try {
                client = signedIn(account)
                if (translator.provider == Provider.DEEP_L) throw AnimeBlockedException(AnimeBlock.PROVIDER)
                review(account, if (operation == PromptOperation.ENHANCE) description else "Generate a non-sexual fully clothed anime character prompt.", safe)
                val action = if (operation == PromptOperation.ENHANCE) "enhance" else "generatePrompt"
                reservation = client.reserve(action, providerCreditId(translator.provider))
                account.afterCall()
                val backend = client.takeIf { translator.provider == Provider.BACKEND }
                val result = animePrompt(translator, operation, description, safe, UUID.randomUUID().toString(), backend, reservation)
                review(account, result.prompt + "\n" + result.character, safe)
                suggestionState.value = PromptSuggestion(description.trim(), result.prompt, result.character, translator.provider.name)
                succeeded = true
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                errorChannel.send(error)
            } finally {
                withContext(NonCancellable) {
                    val r = reservation
                    if (client != null && r != null) {
                        runCatching { if (translator.provider == Provider.BACKEND) client.finishBackend(r) else client.settle(r, succeeded) }
                        account.afterCall()
                    }
                    runCatching { account.refreshCredits() }
                    assistingState.value = false
                }
            }
        }
    }

    fun dismissSuggestion() {
        suggestionState.value = null
    }

    /**
     * Local Anima generation (iPad `generateAnime`): review the prompt in
     * half/full-safe, reserve the `image` credits, generate, then settle;
     * failed or cancelled generation is refunded.
     */
    fun generate(prompt: String, width: Int, height: Int, steps: Int, safe: Boolean, busy: Boolean, account: BackendAccount) {
        val config = config ?: return
        if (generateJob?.isActive == true || assistJob?.isActive == true || busy) return
        deviceBlock?.let {
            errorChannel.trySend(AnimeBlockedException(it))
            return
        }
        val upscaling = upscaleState.value.takeIf { it.enabled }
        val upscaler = upscaling?.let { state -> upscalers.first { it.id == state.selected } }
        if (upscaling != null && !upscaling.selectedReady) {
            errorChannel.trySend(AnimeBlockedException(AnimeBlock.UPSCALER))
            return
        }
        val path = { role: String -> File(modelDir, config.components.first { it.role == role }.file.path).path }
        val seed = Random.nextLong(0, Long.MAX_VALUE)
        generationState.value = Generation(if (safe) 0 else 1)
        generateJob = viewModelScope.launch {
            var client: BackendClient? = null
            var reservation: String? = null
            var succeeded = false
            try {
                client = signedIn(account)
                review(account, prompt, safe)
                reservation = client.reserve("image", "local")
                account.afterCall()
            } catch (error: CancellationException) {
                generationState.value = null
                throw error
            } catch (error: Throwable) {
                errorChannel.send(error)
                generationState.value = null
                return@launch
            }
            generationState.value = Generation(1)
            val job = AnimaJob()
            animaJob = job
            val reporting = launch {
                var latest = Generation(1)
                while (isActive) {
                    val p = job.progress()
                    // The runtime also reports weight-loading counters; only the
                    // configured sampling pass belongs in the bar.
                    latest = when {
                        p.phase == 2 && p.steps == steps && p.step in 1..steps -> Generation(2, p.step, p.steps)
                        p.phase == 2 -> latest.copy(phase = 2)
                        else -> latest
                    }
                    generationState.value = latest
                    delay(250)
                }
            }
            try {
                var rgb = withContext(Dispatchers.Default) {
                    job.generate(AnimaPaths(path("diffusion"), path("textEncoder"), path("vae")), prompt, width.toUInt(), height.toUInt(), steps.toUInt(), seed, 0u)
                }
                reporting.cancel()
                var outWidth = width
                var outHeight = height
                if (upscaler != null) {
                    generationState.value = Generation(4)
                    val model = File(upscalerDir, upscaler.file.path).path
                    rgb = withContext(Dispatchers.Default) { job.upscale(model, rgb, width.toUInt(), height.toUInt(), upscaler.scale, 0u) }
                    outWidth = width * upscaler.scale.toInt()
                    outHeight = height * upscaler.scale.toInt()
                }
                generationState.value = Generation(3)
                val pixels = IntArray(outWidth * outHeight) { i ->
                    val r = rgb[i * 3].toInt() and 0xFF
                    val g = rgb[i * 3 + 1].toInt() and 0xFF
                    val b = rgb[i * 3 + 2].toInt() and 0xFF
                    (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                }
                val bitmap = Bitmap.createBitmap(pixels, outWidth, outHeight, Bitmap.Config.ARGB_8888)
                store.add(bitmap, prompt.trim(), seed, config.id, steps)
                bitmap.recycle()
                succeeded = true
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (error !is uniffi.koharu_core.AnimeException.Cancelled) errorChannel.send(error)
            } finally {
                reporting.cancel()
                animaJob = null
                job.close()
                withContext(NonCancellable) {
                    val r = reservation
                    if (r != null) {
                        runCatching { client?.settle(r, succeeded) }
                        account.afterCall()
                    }
                    runCatching { account.refreshCredits() }
                }
                generationState.value = null
            }
        }
    }

    fun cancelGeneration() {
        animaJob?.cancel()
    }

    fun delete(image: AnimeImage) {
        viewModelScope.launch { runCatching { store.delete(image) }.onFailure { errorChannel.send(it) } }
    }

    fun export(image: AnimeImage, onDone: (Boolean) -> Unit) {
        viewModelScope.launch { onDone(runCatching { store.export(image) }.getOrDefault(false)) }
    }

    private companion object {
        /** Headroom left for the system and the app's own files. */
        const val STORAGE_MARGIN = 200L * 1024 * 1024

        /**
         * Divergence from iPad: Android reports RAM after the kernel's reserve,
         * so an 8 GB phone shows about 7.3–7.6 GB. 90% of the configured
         * minimum admits 8 GB phones and still rejects 6 GB ones.
         */
        fun enoughMemory(context: Context): Boolean {
            val minimum = runCatching { animaConfig().minimumDeviceMemoryBytes.toLong() }.getOrDefault(Long.MAX_VALUE)
            val info = ActivityManager.MemoryInfo()
            (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(info)
            return info.totalMem >= minimum / 10 * 9
        }
    }
}
