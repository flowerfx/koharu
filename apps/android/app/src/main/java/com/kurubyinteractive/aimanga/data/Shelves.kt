package com.kurubyinteractive.aimanga.data

import uniffi.koharu_core.rawkumaSeriesUrl

// Port of apps/ipad/Sources/LibraryShelves.swift.

/** Series page of a Rawkuma chapter, the grouping key for "By manga". */
val Chapter.seriesUrl: String?
    get() {
        val address = source ?: return null
        val host = runCatching { java.net.URI(address).host }.getOrNull() ?: return null
        return rawkumaSeriesUrl("https://$host/", address)
    }

/**
 * Saved series title, or one derived from a page title such as
 * "Series Name Chapter 35 – Rawkuma" for chapters saved without series data.
 */
val Chapter.seriesName: String
    get() {
        series?.title?.takeIf { it.isNotBlank() }?.let { return it }
        val name = title
            .replace(Regex("""\s*[–—-]\s*Rawkuma\s*$""", RegexOption.IGNORE_CASE), "")
            .replace(Regex("""\s+(Chapter|Ch\.?)\s*[0-9][0-9.]*.*$""", RegexOption.IGNORE_CASE), "")
            .trim()
        return name.ifEmpty { title }
    }

/** Chapter number from the title or Rawkuma address, for ordering inside a manga. */
val Chapter.number: Double?
    get() {
        val pattern = Regex("""(?i)chapter[\s-]*([0-9]+(\.[0-9]+)?)""")
        for (text in listOfNotNull(title, source)) {
            pattern.find(text)?.groupValues?.get(1)?.toDoubleOrNull()?.let { return it }
        }
        return null
    }

/** Chapter order inside a manga or project screen. */
enum class ShelfSort { NEWEST, OLDEST, CHAPTER_DESCENDING, CHAPTER_ASCENDING }

fun ShelfSort.apply(chapters: List<Chapter>): List<Chapter> = when (this) {
    ShelfSort.NEWEST -> chapters.sortedByDescending { it.created }
    ShelfSort.OLDEST -> chapters.sortedBy { it.created }
    ShelfSort.CHAPTER_ASCENDING -> readingOrder(chapters)
    ShelfSort.CHAPTER_DESCENDING -> readingOrder(chapters).reversed()
}

/** Numbered chapters first, by number; the rest by date. */
fun readingOrder(chapters: List<Chapter>): List<Chapter> = chapters.sortedWith { a, b ->
    val x = a.number
    val y = b.number
    when {
        x != null && y != null && x != y -> x.compareTo(y)
        x != null && y == null -> -1
        x == null && y != null -> 1
        else -> a.created.compareTo(b.created)
    }
}

/** One row of the "By manga" library: a Rawkuma series, a project, or a loose imported chapter. */
sealed interface Shelf {
    val key: String
    val chapters: List<Chapter>

    data class Series(val url: String, val name: String, override val chapters: List<Chapter>) : Shelf {
        override val key get() = "series:$url"
    }

    data class Folder(val project: Project, override val chapters: List<Chapter>) : Shelf {
        override val key get() = "project:${project.id}"
    }

    data class Loose(val chapter: Chapter) : Shelf {
        override val key get() = "chapter:${chapter.id}"
        override val chapters get() = listOf(chapter)
    }
}

/** Series and projects first (most recently added chapter first), then loose imports. */
fun shelves(chapters: List<Chapter>, projects: List<Project>): List<Shelf> {
    val series = LinkedHashMap<String, MutableList<Chapter>>()
    val names = HashMap<String, String>()
    val inProject = HashMap<String, MutableList<Chapter>>()
    val loose = mutableListOf<Chapter>()
    val known = projects.map { it.id }.toSet()
    for (chapter in chapters) {
        val url = chapter.seriesUrl
        val project = chapter.projectId
        when {
            url != null -> {
                series.getOrPut(url) { mutableListOf() } += chapter
                if (chapter.series != null || url !in names) names[url] = chapter.seriesName
            }
            project != null && project in known -> inProject.getOrPut(project) { mutableListOf() } += chapter
            else -> loose += chapter
        }
    }
    fun latest(items: List<Chapter>) = items.maxOfOrNull { it.created } ?: 0L
    val groups = series.map { (url, items) -> latest(items) to Shelf.Series(url, names[url] ?: url, readingOrder(items)) } +
        projects.map { p -> maxOf(latest(inProject[p.id].orEmpty()), p.created) to Shelf.Folder(p, readingOrder(inProject[p.id].orEmpty())) }
    return groups.sortedByDescending { it.first }.map { it.second } +
        loose.sortedByDescending { it.created }.map { Shelf.Loose(it) }
}
