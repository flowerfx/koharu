import Foundation

/// A user folder for imported chapters.
struct MangaProject: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var note = ""
    var created = Date()
}

enum LibraryMode: String, CaseIterable, Identifiable {
    case all, manga
    var id: String { rawValue }
    var title: String { L(self == .all ? "All chapters" : "By manga") }
}

extension Chapter {
    var isImported: Bool { sourceURL.hasPrefix("imported://") }
    /// Series page on Rawkuma, the grouping key for "By manga".
    @MainActor var seriesURL: String? { isImported ? nil : RawkumaGenreChecker.seriesURL(sourceURL)?.absoluteString }
    /// Saved series title, or one derived from a page title such as
    /// "Series Name Chapter 35 – Rawkuma" for chapters saved before titles were kept.
    var seriesName: String {
        if let seriesTitle, !seriesTitle.isEmpty { return seriesTitle }
        var name = title
        if let range = name.range(of: #"\s*[–—-]\s*Rawkuma\s*$"#, options: [.regularExpression, .caseInsensitive]) { name.removeSubrange(range) }
        if let range = name.range(of: #"\s+(Chapter|Ch\.?)\s*[0-9][0-9.]*.*$"#, options: [.regularExpression, .caseInsensitive]) { name.removeSubrange(range) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }
    /// Chapter number from the title or Rawkuma URL, for ordering inside a manga.
    var number: Double? {
        for text in [title, sourceURL] {
            if let range = text.range(of: #"(?i)chapter[\s-]*([0-9]+(\.[0-9]+)?)"#, options: .regularExpression),
               let digits = text[range].range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression) {
                return Double(text[range][digits])
            }
        }
        return nil
    }
    var renderedCount: Int { pages.filter { $0.rendered != nil }.count }
}

/// Chapter order inside a manga or project screen.
enum ShelfSort: String, CaseIterable, Identifiable {
    case newest, oldest, chapterDescending, chapterAscending
    var id: String { rawValue }
    var byChapter: Bool { self == .chapterDescending || self == .chapterAscending }
    var title: String {
        switch self {
        case .newest: return L("Newest first")
        case .oldest: return L("Oldest first")
        case .chapterDescending: return L("Latest chapter first")
        case .chapterAscending: return L("First chapter first")
        }
    }
    var symbol: String {
        switch self {
        case .newest, .chapterDescending: return "arrow.down"
        case .oldest, .chapterAscending: return "arrow.up"
        }
    }
    /// Date orders use when a chapter was added; chapter orders use its number.
    func apply(_ chapters: [Chapter]) -> [Chapter] {
        switch self {
        case .newest: return chapters.sorted { $0.created > $1.created }
        case .oldest: return chapters.sorted { $0.created < $1.created }
        case .chapterAscending: return LibraryShelf.ordered(chapters)
        case .chapterDescending: return Array(LibraryShelf.ordered(chapters).reversed())
        }
    }
}

/// One row of the "By manga" library: a Rawkuma series, a project, or an
/// imported chapter that belongs to no project.
enum LibraryShelf: Identifiable {
    case series(url: String, name: String, chapters: [Chapter])
    case project(MangaProject, chapters: [Chapter])
    case chapter(Chapter)
    var id: String {
        switch self {
        case .series(let url, _, _): return "series:" + url
        case .project(let project, _): return "project:" + project.id.uuidString
        case .chapter(let chapter): return "chapter:" + chapter.id.uuidString
        }
    }

    /// Chapters inside a manga or project, in reading order.
    static func ordered(_ chapters: [Chapter]) -> [Chapter] {
        chapters.sorted {
            switch ($0.number, $1.number) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.created < $1.created
            }
        }
    }

    /// Series and projects first (most recently added chapter first), then loose imports.
    @MainActor static func shelves(_ chapters: [Chapter], projects: [MangaProject]) -> [LibraryShelf] {
        var series: [String: [Chapter]] = [:], names: [String: String] = [:], loose: [Chapter] = []
        var inProject: [UUID: [Chapter]] = [:]
        let known = Set(projects.map(\.id))
        for chapter in chapters {
            if let url = chapter.seriesURL {
                series[url, default: []].append(chapter)
                if chapter.seriesTitle != nil || names[url] == nil { names[url] = chapter.seriesName }
            } else if let project = chapter.projectID, known.contains(project) {
                inProject[project, default: []].append(chapter)
            } else {
                loose.append(chapter)
            }
        }
        func latest(_ items: [Chapter]) -> Date { items.map(\.created).max() ?? .distantPast }
        var groups: [(Date, LibraryShelf)] = series.map { (latest($1), .series(url: $0, name: names[$0] ?? $0, chapters: ordered($1))) }
        groups += projects.map { (max(latest(inProject[$0.id] ?? []), $0.created), .project($0, chapters: ordered(inProject[$0.id] ?? []))) }
        return groups.sorted { $0.0 > $1.0 }.map(\.1) + loose.sorted { $0.created > $1.created }.map { .chapter($0) }
    }
}

extension LibraryDisk {
    var projectsURL: URL { root.appendingPathComponent("projects.json") }
    func projects() throws -> [MangaProject] {
        FileManager.default.fileExists(atPath: projectsURL.path) ? try load([MangaProject].self, projectsURL) : []
    }
}

extension MangaLibrary {
    func project(_ id: UUID?) -> MangaProject? { id.flatMap { id in projects.first { $0.id == id } } }
    @discardableResult
    func saveProject(_ project: MangaProject) -> MangaProject? {
        var value = project
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.note = value.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { error = L("Enter a project name."); return nil }
        var updated = projects
        if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value } else { updated.append(value) }
        do { try disk.save(updated, to: disk.projectsURL); projects = updated; return value }
        catch { self.error = error.localizedDescription; return nil }
    }
    /// Deleting a project either deletes its chapters too, or keeps them as loose imports.
    func deleteProject(_ id: UUID, deletingChapters: Bool = false) {
        guard !busy else { return }
        if deletingChapters { delete(chapters.filter { $0.isImported && $0.projectID == id }.map(\.id)) }
        let updated = projects.filter { $0.id != id }
        do {
            for chapter in chapters where chapter.projectID == id { var value = chapter; value.projectID = nil; try update(value, recordUndo: false) }
            try disk.save(updated, to: disk.projectsURL); projects = updated
        } catch { self.error = error.localizedDescription }
    }
    /// Deletes every chapter of a Rawkuma series or a project; the project itself stays.
    func deleteChapters(in kind: ShelfScreen.Kind) {
        delete(chapters.filter { chapter in
            switch kind {
            case .series(let url, _): return chapter.seriesURL == url
            case .project(let id): return chapter.isImported && chapter.projectID == id
            }
        }.map(\.id))
    }
    /// Only imported chapters belong to projects; Rawkuma chapters group by series.
    func move(_ chapterID: UUID, to project: UUID?) {
        guard var chapter = chapters.first(where: { $0.id == chapterID }), chapter.isImported, project == nil || self.project(project) != nil else { return }
        chapter.projectID = project
        do { try update(chapter, recordUndo: false) } catch { self.error = error.localizedDescription }
    }
}
