package com.kurubyinteractive.aimanga

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.graphics.Bitmap
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
import kotlin.random.Random

/** Why Anime Studio cannot run here. */
enum class AnimeBlock { UNSUPPORTED_ABI, MEMORY, CONTENT_REVIEW }

class AnimeBlockedException(val reason: AnimeBlock) : IllegalStateException()

data class AnimaModelState(
    val ready: Boolean,
    val downloading: Boolean = false,
    val done: Long = 0,
    val total: Long = 0,
)

/** 1 loading the model, 2 sampling (step/steps), 3 saving. */
data class Generation(val phase: Int, val step: Int = 0, val steps: Int = 0)

/**
 * Anime Studio (port of the iPad `MangaLibrary` anime flow): download the
 * Anima components from anima-config.json, then generate locally.
 */
class AnimeStudioModel(application: Application) : AndroidViewModel(application) {
    val store = AnimeStore(application)
    val config: AnimaConfig? = runCatching { animaConfig() }.getOrNull()
    private val modelDir = File(application.filesDir, "models/${config?.id ?: "anima"}")

    private val modelState = MutableStateFlow(AnimaModelState(ready()))
    val model: StateFlow<AnimaModelState> = modelState.asStateFlow()
    private var downloadJob: Job? = null
    @Volatile private var stopDownload = false

    private val generationState = MutableStateFlow<Generation?>(null)
    val generation: StateFlow<Generation?> = generationState.asStateFlow()
    private var generateJob: Job? = null
    private var animaJob: AnimaJob? = null

    private val errorChannel = Channel<Throwable>(Channel.BUFFERED)
    val errors = errorChannel.receiveAsFlow()

    val totalBytes: Long get() = config?.components?.sumOf { it.file.bytes.toLong() } ?: 0

    /** The reason generation is unavailable on this device, if any (before content review). */
    val deviceBlock: AnimeBlock? = when {
        !animaAvailable() -> AnimeBlock.UNSUPPORTED_ABI
        !enoughMemory(application) -> AnimeBlock.MEMORY
        else -> null
    }

    private fun ready() = config != null && config.components.all { animaFileReady(it.file, modelDir.path) }

    fun download() {
        val config = config ?: return
        if (downloadJob?.isActive == true) return
        stopDownload = false
        downloadJob = viewModelScope.launch {
            try {
                var base = 0L
                for (component in config.components) {
                    val file = component.file
                    if (!animaFileReady(file, modelDir.path)) {
                        val offset = base
                        downloadAnimaFile(file, modelDir.path, object : ModelDownloadProgress {
                            override fun onBytes(done: ULong, total: ULong) {
                                modelState.value = AnimaModelState(false, true, offset + done.toLong(), totalBytes)
                            }
                            override fun isCancelled() = stopDownload
                        })
                    }
                    base += file.bytes.toLong()
                    modelState.value = AnimaModelState(false, true, base, totalBytes)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (!stopDownload) errorChannel.send(error)
            } finally {
                modelState.value = AnimaModelState(ready())
            }
        }
    }

    fun cancelDownload() {
        stopDownload = true
    }

    fun deleteModel() {
        if (downloadJob?.isActive == true || generationState.value != null) return
        modelDir.deleteRecursively()
        modelState.value = AnimaModelState(ready())
    }

    /** Generation needs no prompt review only in `none-safe`, which has no backend dependency. */
    fun generate(prompt: String, width: Int, height: Int, steps: Int, safetyMode: String, busy: Boolean) {
        val config = config ?: return
        if (generateJob?.isActive == true || busy) return
        val block = deviceBlock ?: AnimeBlock.CONTENT_REVIEW.takeIf { safetyMode != "none-safe" }
        if (block != null) {
            errorChannel.trySend(AnimeBlockedException(block))
            return
        }
        val path = { role: String -> File(modelDir, config.components.first { it.role == role }.file.path).path }
        val seed = Random.nextLong(0, Long.MAX_VALUE)
        generationState.value = Generation(1)
        generateJob = viewModelScope.launch {
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
                val rgb = withContext(Dispatchers.Default) {
                    job.generate(AnimaPaths(path("diffusion"), path("textEncoder"), path("vae")), prompt, width.toUInt(), height.toUInt(), steps.toUInt(), seed, 0u)
                }
                reporting.cancel()
                generationState.value = Generation(3)
                val pixels = IntArray(width * height) { i ->
                    val r = rgb[i * 3].toInt() and 0xFF
                    val g = rgb[i * 3 + 1].toInt() and 0xFF
                    val b = rgb[i * 3 + 2].toInt() and 0xFF
                    (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                }
                val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
                store.add(bitmap, prompt.trim(), seed, config.id, steps)
                bitmap.recycle()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (error !is uniffi.koharu_core.AnimeException.Cancelled) errorChannel.send(error)
            } finally {
                reporting.cancel()
                animaJob = null
                job.close()
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
