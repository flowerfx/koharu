package com.kurubyinteractive.aimanga.pipeline

import android.graphics.Bitmap
import com.kurubyinteractive.aimanga.data.Chapter
import com.kurubyinteractive.aimanga.data.Library
import com.kurubyinteractive.aimanga.data.Segment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import uniffi.koharu_core.BackendClient
import uniffi.koharu_core.TranslatorConfig
import uniffi.koharu_core.mergeLines
import uniffi.koharu_core.translate

sealed interface Progress {
    data class Reading(val page: Int, val total: Int) : Progress
    data class Translating(val segments: Int) : Progress
    data class Rendering(val page: Int, val total: Int) : Progress
}

/**
 * Chapter pipeline: OCR the pending pages, translate their segments in
 * batched requests (Rust core), then letter them. Without [force] pages that
 * already have a translation are skipped; [only] limits a run to one page.
 */
class ChapterTranslator(private val library: Library) {

    suspend fun run(
        chapter: Chapter,
        config: TranslatorConfig,
        backend: BackendClient?,
        force: Boolean,
        only: Int?,
        onProgress: (Progress) -> Unit,
    ): Chapter = withContext(Dispatchers.Default) {
        val total = chapter.pages.size
        val pending = chapter.pages.indices.filter { (only == null || it == only) && (force || chapter.pages[it].translated == null) }
        if (pending.isEmpty()) return@withContext chapter

        // OCR results are kept, so a retry or a rerun does not read pages again.
        var current = chapter
        JapaneseOcr().use { ocr ->
            for (index in pending) {
                ensureActive()
                onProgress(Progress.Reading(index + 1, total))
                val page = current.pages[index]
                if (page.segments.isNotEmpty()) continue
                val bitmap = decodePage(library.file(current, page.file))
                val segments = try {
                    mergeLines(ocr.lines(bitmap)).map { Segment(it.source, it.rect.x, it.rect.y, it.rect.width, it.rect.height) }
                } finally {
                    bitmap.recycle()
                }
                current = current.copy(pages = current.pages.toMutableList().also { it[index] = page.copy(segments = segments) })
            }
        }
        library.save(current)

        val texts = pending.flatMap { current.pages[it].segments }.map { it.source }
        onProgress(Progress.Translating(texts.size))
        val translations = translate(config, texts, backend)
        var next = 0
        val translated = pending.associateWith { index -> current.pages[index].segments.map { it.copy(translation = translations[next++]) } }

        val stamp = System.currentTimeMillis()
        for (index in pending) {
            ensureActive()
            onProgress(Progress.Rendering(index + 1, total))
            val page = current.pages[index]
            val source = decodePage(library.file(current, page.file))
            val rendered = PageRenderer.render(source, translated.getValue(index))
            source.recycle()
            // A new name per run keeps image caches from showing a stale render.
            val name = "translated-%03d-%d.png".format(index + 1, stamp)
            library.file(current, name).outputStream().use { rendered.compress(Bitmap.CompressFormat.PNG, 100, it) }
            rendered.recycle()
            page.translated?.let { library.file(current, it).delete() }
            current = current.copy(
                target = config.targetLanguage,
                pages = current.pages.toMutableList().also { it[index] = page.copy(translated = name, segments = translated.getValue(index)) },
            )
            library.save(current)
        }
        current
    }
}
