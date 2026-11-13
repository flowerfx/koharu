package com.kurubyinteractive.aimanga.data

import android.content.Context
import android.net.Uri
import android.webkit.MimeTypeMap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import uniffi.koharu_core.SeriesContext
import java.io.File
import java.util.UUID

/** One OCR region with its page-normalized rectangle and translation. */
data class Segment(
    val source: String,
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
    val translation: String? = null,
)

data class Page(
    val file: String,
    /** Rendered translated page, once the chapter has been translated. */
    val translated: String? = null,
    val segments: List<Segment> = emptyList(),
)

data class Chapter(
    val id: String,
    val title: String,
    val created: Long,
    val pages: List<Page>,
    /** Rawkuma chapter address, for chapters downloaded from the source browser. */
    val source: String? = null,
    /** Series description sent with translation as reference data. */
    val series: SeriesContext? = null,
    /** Project folder of an imported chapter; Rawkuma chapters group by series instead. */
    val projectId: String? = null,
    /** Target language tag of the saved translations. */
    val target: String? = null,
) {
    val translatedPages: Int get() = pages.count { it.translated != null }
    val isImported: Boolean get() = source == null
}

/** A user folder for imported chapters (iPad `MangaProject`). */
data class Project(val id: String, val name: String, val note: String, val created: Long)

/** Chapters live in app storage: `library/<id>/chapter.json` plus page images. */
class Library(context: Context) {
    private val root = File(context.filesDir, "library").apply { mkdirs() }
    private val resolver = context.contentResolver
    private val state = MutableStateFlow(load())
    val chapters: StateFlow<List<Chapter>> = state.asStateFlow()
    private val projectsFile = File(root, "projects.json")
    private val projectState = MutableStateFlow(loadProjects())
    val projects: StateFlow<List<Project>> = projectState.asStateFlow()

    /** Bytes on disk of a chapter: its JSON plus original and translated pages. */
    fun bytes(chapter: Chapter): Long =
        File(root, chapter.id).walkTopDown().filter { it.isFile }.sumOf { it.length() }

    /** Creates or renames a project; returns null for an empty name. */
    fun saveProject(project: Project): Project? {
        val value = project.copy(name = project.name.trim(), note = project.note.trim())
        if (value.name.isEmpty()) return null
        val updated = projectState.value.filter { it.id != value.id } + value
        writeProjects(updated.sortedBy { it.created })
        return value
    }

    /** Deleting a project keeps its chapters; they return to the loose imports. */
    fun deleteProject(id: String) {
        state.value.filter { it.projectId == id }.forEach { save(it.copy(projectId = null)) }
        writeProjects(projectState.value.filter { it.id != id })
    }

    /** Only imported chapters belong to projects. */
    fun move(chapter: Chapter, projectId: String?) {
        if (!chapter.isImported || (projectId != null && projectState.value.none { it.id == projectId })) return
        save(chapter.copy(projectId = projectId))
    }

    private fun writeProjects(projects: List<Project>) {
        val temporary = File(root, "projects.json.tmp")
        temporary.writeText(JSONArray(projects.map {
            JSONObject().put("id", it.id).put("name", it.name).put("note", it.note).put("created", it.created)
        }).toString())
        check(temporary.renameTo(projectsFile)) { "Could not save projects" }
        projectState.value = projects
    }

    private fun loadProjects(): List<Project> = runCatching {
        val array = JSONArray(File(root, "projects.json").readText())
        List(array.length()) { i ->
            val o = array.getJSONObject(i)
            Project(o.getString("id"), o.getString("name"), o.optString("note"), o.getLong("created"))
        }
    }.getOrDefault(emptyList())

    fun file(chapter: Chapter, name: String) = File(File(root, chapter.id), name)

    fun chapter(id: String) = state.value.firstOrNull { it.id == id }

    suspend fun import(title: String, uris: List<Uri>, projectId: String? = null): Chapter = withContext(Dispatchers.IO) {
        val id = UUID.randomUUID().toString()
        val dir = File(root, id).apply { mkdirs() }
        try {
            val pages = uris.mapIndexed { index, uri ->
                val extension = resolver.getType(uri)
                    ?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) } ?: "jpg"
                val name = "page-%03d.%s".format(index + 1, extension)
                resolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { "Cannot open $uri" }
                    File(dir, name).outputStream().use { input.copyTo(it) }
                }
                Page(name)
            }
            Chapter(id, title, System.currentTimeMillis(), pages, projectId = projectId).also { save(it) }
        } catch (error: Throwable) {
            dir.deleteRecursively()
            throw error
        }
    }

    /**
     * Creates a chapter from pages that [download] writes into the new chapter
     * folder; it returns their file names in page order.
     */
    suspend fun create(
        title: String,
        source: String?,
        series: SeriesContext?,
        download: suspend (File) -> List<String>,
    ): Chapter {
        val id = UUID.randomUUID().toString()
        val dir = File(root, id).apply { mkdirs() }
        try {
            val pages = download(dir).map { Page(it) }
            return withContext(Dispatchers.IO) {
                Chapter(id, title, System.currentTimeMillis(), pages, source, series).also { save(it) }
            }
        } catch (error: Throwable) {
            dir.deleteRecursively()
            throw error
        }
    }

    /**
     * A copy of [chapter] for another target language, keeping its pages and
     * OCR but no translations, so the earlier translation is not overwritten.
     */
    suspend fun copyForTarget(chapter: Chapter, target: String): Chapter = withContext(Dispatchers.IO) {
        val id = UUID.randomUUID().toString()
        val dir = File(root, id).apply { mkdirs() }
        chapter.pages.forEach { File(File(root, chapter.id), it.file).copyTo(File(dir, it.file)) }
        val copy = chapter.copy(
            id = id,
            created = System.currentTimeMillis(),
            target = target,
            pages = chapter.pages.map { page -> page.copy(translated = null, segments = page.segments.map { it.copy(translation = null) }) },
        )
        save(copy)
        copy
    }

    fun save(chapter: Chapter) {
        val dir = File(root, chapter.id)
        val temporary = File(dir, "chapter.json.tmp")
        temporary.writeText(encode(chapter).toString())
        // Rename is atomic, so an interrupted save never leaves a torn file.
        check(temporary.renameTo(File(dir, "chapter.json"))) { "Could not save chapter" }
        state.update { list -> (list.filter { it.id != chapter.id } + chapter).sortedByDescending { it.created } }
    }

    fun delete(chapter: Chapter) {
        File(root, chapter.id).deleteRecursively()
        state.update { list -> list.filter { it.id != chapter.id } }
    }

    private fun load(): List<Chapter> = root.listFiles().orEmpty().mapNotNull { dir ->
        runCatching { decode(dir.name, JSONObject(File(dir, "chapter.json").readText())) }.getOrNull()
    }.sortedByDescending { it.created }

    private fun encode(chapter: Chapter) = JSONObject().apply {
        put("title", chapter.title)
        put("created", chapter.created)
        chapter.source?.let { put("source", it) }
        chapter.projectId?.let { put("projectId", it) }
        chapter.target?.let { put("target", it) }
        chapter.series?.let { series ->
            put("series", JSONObject().apply {
                put("title", series.title)
                put("alternativeTitles", JSONArray(series.alternativeTitles))
                put("genres", JSONArray(series.genres))
                put("synopsis", series.synopsis)
            })
        }
        put("pages", JSONArray(chapter.pages.map { page ->
            JSONObject().apply {
                put("file", page.file)
                page.translated?.let { put("translated", it) }
                put("segments", JSONArray(page.segments.map { s ->
                    JSONObject().apply {
                        put("source", s.source)
                        put("x", s.x); put("y", s.y); put("width", s.width); put("height", s.height)
                        s.translation?.let { put("translation", it) }
                    }
                }))
            }
        }))
    }

    private fun decode(id: String, json: JSONObject): Chapter {
        val pages = json.getJSONArray("pages")
        return Chapter(
            id = id,
            title = json.getString("title"),
            created = json.getLong("created"),
            source = json.optString("source").ifEmpty { null },
            projectId = json.optString("projectId").ifEmpty { null },
            target = json.optString("target").ifEmpty { null },
            series = json.optJSONObject("series")?.let { s ->
                fun strings(name: String) = s.getJSONArray(name).let { a -> List(a.length()) { a.getString(it) } }
                SeriesContext(s.getString("title"), strings("alternativeTitles"), strings("genres"), s.getString("synopsis"))
            },
            pages = List(pages.length()) { i ->
                val page = pages.getJSONObject(i)
                val segments = page.optJSONArray("segments") ?: JSONArray()
                Page(
                    file = page.getString("file"),
                    translated = page.optString("translated").ifEmpty { null },
                    segments = List(segments.length()) { j ->
                        val s = segments.getJSONObject(j)
                        Segment(
                            source = s.getString("source"),
                            x = s.getDouble("x"), y = s.getDouble("y"),
                            width = s.getDouble("width"), height = s.getDouble("height"),
                            translation = if (s.has("translation")) s.getString("translation") else null,
                        )
                    },
                )
            },
        )
    }
}
