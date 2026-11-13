import SwiftUI

/// Every screen pushed on the library stack is a value, so a chapter opened
/// from a manga or project shelf joins the same navigation path.
enum LibraryRoute: Hashable {
    case chapter(UUID)
    case shelf(ShelfScreen.Kind)
}

struct LibraryScreen: View {
    @Environment(MangaLibrary.self) private var library
    var openSource: (String) -> Void
    var browse: () -> Void
    @AppStorage("libraryMode") private var mode = LibraryMode.all
    @State private var deleting: Chapter?
    @State private var deletingAll = false
    @State private var editingProject: MangaProject?
    @State private var searchText = ""
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ chapter: Chapter) -> Bool {
        query.isEmpty || chapter.title.localizedStandardContains(query) || chapter.seriesName.localizedStandardContains(query) ||
            library.project(chapter.projectID)?.name.localizedStandardContains(query) == true
    }
    private var visibleChapters: [Chapter] { library.chapters.filter(matches) }
    private var shelves: [LibraryShelf] {
        LibraryShelf.shelves(visibleChapters, projects: library.projects.filter { project in
            query.isEmpty || project.name.localizedStandardContains(query) || visibleChapters.contains { $0.projectID == project.id }
        })
    }
    var body: some View {
        List {
            Section {
                Picker(L("Library view"), selection: $mode) {
                    ForEach(LibraryMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if library.chapters.isEmpty && library.projects.isEmpty {
                ContentUnavailableView {
                    Label(L("Your manga library"), systemImage: "books.vertical")
                } description: { Text(AppConfiguration.current.allowsRawkuma ? L("Browse Rawkuma and translate a chapter. Saved chapters stay on this device.") : L("Import images or an image folder from Files, then translate them in your library.")) } actions: { Button(AppConfiguration.current.allowsRawkuma ? MainTab.browser.title : MainTab.importManga.title, action: browse).buttonStyle(.borderedProminent) }
            } else if !query.isEmpty && visibleChapters.isEmpty && shelves.isEmpty {
                ContentUnavailableView(L("No matching chapters"), systemImage: "magnifyingglass", description: Text(L("Try another chapter title.")))
            }
            switch mode {
            case .all:
                Section {
                    ForEach(visibleChapters) { chapter in
                        NavigationLink(value: LibraryRoute.chapter(chapter.id)) { LibraryChapterRow(chapter: chapter, showsOrigin: true) }
                            .chapterActions(chapter, openSource: openSource, deleting: $deleting)
                    }
                } header: {
                    Text("\(L("Chapters")): \(query.isEmpty ? "\(library.chapters.count)" : "\(visibleChapters.count) / \(library.chapters.count)")")
                        .monospacedDigit().textCase(nil)
                }
            case .manga:
                let shelves = shelves
                if shelves.contains(where: { if case .chapter = $0 { false } else { true } }) {
                    Section(L("Manga and projects")) {
                        ForEach(shelves) { shelf in
                            switch shelf {
                            case .series(let url, let name, let chapters):
                                HStack {
                                    NavigationLink(value: LibraryRoute.shelf(.series(url: url, name: name))) { SeriesRow(name: name, url: url, chapters: chapters) }
                                    Button { openSource(url) } label: { Image(systemName: "globe") }
                                        .buttonStyle(.borderless).accessibilityLabel(L("Manga page"))
                                        .disabled(!AppConfiguration.current.allowsRawkuma)
                                }
                            case .project(let project, let chapters):
                                NavigationLink(value: LibraryRoute.shelf(.project(project.id))) { ProjectRow(project: project, chapters: chapters) }
                                .contextMenu {
                                    Button(L("Edit project"), systemImage: "pencil") { editingProject = project }
                                }
                            case .chapter: EmptyView()
                            }
                        }
                    }
                }
                let loose = shelves.compactMap { if case .chapter(let chapter) = $0 { chapter } else { nil } }
                if !loose.isEmpty {
                    Section(L("Imported chapters")) {
                        ForEach(loose) { chapter in
                            NavigationLink(value: LibraryRoute.chapter(chapter.id)) { LibraryChapterRow(chapter: chapter, showsOrigin: false) }
                                .chapterActions(chapter, openSource: openSource, deleting: $deleting)
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Library"))
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Search chapters"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(L("New project"), systemImage: "folder.badge.plus") { editingProject = MangaProject(name: "") }
                Button(L("Delete all chapters"), systemImage: "trash") { deletingAll = true }
                    .disabled(library.busy || library.chapters.isEmpty)
                Button(AppConfiguration.current.allowsRawkuma ? MainTab.browser.title : MainTab.importManga.title,
                       systemImage: AppConfiguration.current.allowsRawkuma ? "globe" : "square.and.arrow.down", action: browse)
            }
        }
        .sheet(item: $editingProject) { project in ProjectEditor(project: project) }
        .chapterDeletion($deleting)
        .confirmationDialog(L("Delete all saved chapters?"), isPresented: $deletingAll, titleVisibility: .visible) {
            Button(L("Delete all chapters"), role: .destructive) { library.delete(library.chapters.map(\.id)) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Original images, translations and chapter history will be permanently deleted. Downloaded models and settings are kept."))
        }
    }
}

/// Chapters of one Rawkuma series or one project, in reading order.
struct ShelfScreen: View {
    enum Kind: Hashable { case series(url: String, name: String), project(UUID) }
    @Environment(MangaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    var openSource: (String) -> Void
    @State private var deleting: Chapter?
    @State private var editing: MangaProject?
    @State private var deletingProject = false
    @AppStorage("shelfSort") private var savedSort = ShelfSort.chapterAscending
    private var isSeries: Bool { if case .series = kind { true } else { false } }
    /// Chapter-number orders apply to manga only; a project falls back to date order.
    private var sort: ShelfSort { isSeries || !savedSort.byChapter ? savedSort : .oldest }
    private var chapters: [Chapter] {
        LibraryShelf.ordered(library.chapters.filter { chapter in
            switch kind {
            case .series(let url, _): return chapter.seriesURL == url
            case .project(let id): return chapter.isImported && chapter.projectID == id
            }
        })
    }
    /// The chapter to continue: the last one with reading progress, else the first.
    private var next: Chapter? { chapters.last { $0.readPage > 0 } ?? chapters.first }
    var body: some View {
        let chapters = chapters
        List {
            Section {
                switch kind {
                case .series(let url, let name):
                    LabeledContent(L("Manga"), value: name)
                    Button { openSource(url) } label: {
                        Label { Text(url).font(.caption).lineLimit(2).truncationMode(.middle) } icon: { Image(systemName: "globe") }
                    }.disabled(!AppConfiguration.current.allowsRawkuma)
                case .project(let id):
                    if let project = library.project(id) {
                        LabeledContent(L("Project"), value: project.name)
                        if !project.note.isEmpty { Text(project.note).font(.callout).foregroundStyle(.secondary) }
                    }
                }
                LabeledContent(L("Chapters"), value: "\(chapters.count)")
                LabeledContent(L("Pages"), value: "\(chapters.reduce(0) { $0 + $1.pages.count })")
                if let next {
                    NavigationLink(value: LibraryRoute.chapter(next.id)) {
                        Label("\(L("Continue reading")): \(next.title)", systemImage: "book").lineLimit(2)
                    }
                }
            }
            Section(L("Chapters")) {
                if chapters.isEmpty {
                    Text(L("No chapters yet. Move imported chapters here from the library.")).foregroundStyle(.secondary)
                }
                ForEach(sort.apply(chapters)) { chapter in
                    NavigationLink(value: LibraryRoute.chapter(chapter.id)) { LibraryChapterRow(chapter: chapter, showsOrigin: false) }
                        .chapterActions(chapter, openSource: openSource, deleting: $deleting)
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            Menu {
                Picker(L("Sort"), selection: Binding(get: { sort }, set: { savedSort = $0 })) {
                    ForEach(ShelfSort.allCases.filter { isSeries || !$0.byChapter }) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel(L("Sort"))
            if case .project(let id) = kind, let project = library.project(id) {
                Menu {
                    Button(L("Edit project"), systemImage: "pencil") { editing = project }
                    Button(L("Delete project"), systemImage: "trash", role: .destructive) { deletingProject = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $editing) { ProjectEditor(project: $0) }
        .chapterDeletion($deleting)
        .confirmationDialog(L("Delete this project?"), isPresented: $deletingProject, titleVisibility: .visible) {
            Button(L("Delete project"), role: .destructive) {
                if case .project(let id) = kind { library.deleteProject(id); dismiss() }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { Text(L("Its chapters are kept and move back to Imported chapters.")) }
    }
    private var title: String {
        switch kind {
        case .series(_, let name): return name
        case .project(let id): return library.project(id)?.name ?? L("Project")
        }
    }
}

struct LibraryChapterRow: View {
    @Environment(MangaLibrary.self) private var library
    let chapter: Chapter
    /// Shows which manga or import a chapter came from, for the flat list.
    let showsOrigin: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(chapter.title).font(.headline).lineLimit(2)
            if showsOrigin {
                if chapter.isImported {
                    Label(library.project(chapter.projectID).map { "\(L("Imported")) · \($0.name)" } ?? L("Imported"), systemImage: "square.and.arrow.down")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Label(chapter.seriesName, systemImage: "book.closed").font(.caption).foregroundStyle(.pink).lineLimit(1)
                }
            }
            Text("\(chapter.pages.count) \(L("pages")) · \(AppLocalization.shared.locale.localizedString(forIdentifier: chapter.target) ?? chapter.target)" +
                 (chapter.readPage > 0 ? " · \(L("Read")) \(min(chapter.readPage + 1, chapter.pages.count))/\(chapter.pages.count)" : ""))
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(chapter.renderedCount), total: Double(max(1, chapter.pages.count))).tint(.pink)
        }.padding(.vertical, 8)
    }
}

private struct SeriesRow: View {
    let name: String
    let url: String
    let chapters: [Chapter]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(name, systemImage: "book.closed").font(.headline).lineLimit(2)
            Text("\(chapters.count) \(L("chapters"))" + (chapters.last { $0.readPage > 0 }.map { " · \(L("Last read")): \($0.number.map { "\(L("Chapter")) \($0.formatted())" } ?? $0.title)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(url).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }.padding(.vertical, 6)
    }
}

private struct ProjectRow: View {
    let project: MangaProject
    let chapters: [Chapter]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(project.name, systemImage: "folder").font(.headline).lineLimit(2)
            Text("\(chapters.count) \(L("chapters")) · \(chapters.reduce(0) { $0 + $1.pages.count }) \(L("pages"))")
                .font(.caption).foregroundStyle(.secondary)
            if !project.note.isEmpty { Text(project.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(.vertical, 6)
    }
}

/// Create or edit a project's name and note.
struct ProjectEditor: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State var project: MangaProject
    var onSave: (MangaProject) -> Void = { _ in }
    var body: some View {
        NavigationStack {
            Form {
                TextField(L("Project name"), text: $project.name)
                TextField(L("Note (optional)"), text: $project.note, axis: .vertical).lineLimit(3...6)
            }
            .navigationTitle(library.project(project.id) == nil ? L("New project") : L("Edit project"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) { if let saved = library.saveProject(project) { onSave(saved); dismiss() } }
                        .disabled(project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ChapterActions: ViewModifier {
    @Environment(MangaLibrary.self) private var library
    let chapter: Chapter
    var openSource: (String) -> Void
    @Binding var deleting: Chapter?
    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(L("Delete"), systemImage: "trash", role: .destructive) { deleting = chapter }.disabled(library.busy)
            }
            .contextMenu {
                Button(L("Original chapter"), systemImage: "globe") { openSource(chapter.sourceURL) }
                    .disabled(!AppConfiguration.current.allowsRawkuma || AppConfiguration.current.rawkuma?.contains(chapter.sourceURL) != true)
                Button(library.preferences.provider == .backend ? "\(L("Translate")) · \(library.rerunCreditCost) \(L("credits"))" : L("Translate"), systemImage: "arrow.clockwise") { library.run(chapter.id, force: true) }.disabled(library.busy)
                Button("\(L("Enhanced translation")) · \(library.creditCost(.translateEnhanced)) \(L("credits"))", systemImage: "sparkles") { library.run(chapter.id, force: true, enhanced: true) }.disabled(library.busy)
                if chapter.isImported {
                    Menu(L("Move to project"), systemImage: "folder") {
                        Picker(L("Project"), selection: Binding(get: { chapter.projectID }, set: { library.move(chapter.id, to: $0) })) {
                            Text(L("No project")).tag(UUID?.none)
                            ForEach(library.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
                Divider()
                Button(L("Delete"), systemImage: "trash", role: .destructive) { deleting = chapter }.disabled(library.busy)
            }
    }
}

private struct ChapterDeletion: ViewModifier {
    @Environment(MangaLibrary.self) private var library
    @Binding var deleting: Chapter?
    func body(content: Content) -> some View {
        content.confirmationDialog(L("Delete this saved chapter?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) { if let deleting { library.delete([deleting.id]) }; deleting = nil }
            Button(L("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L("Original images, translations and chapter history will be permanently deleted. Downloaded models and settings are kept."))
        }
    }
}

extension View {
    func chapterActions(_ chapter: Chapter, openSource: @escaping (String) -> Void, deleting: Binding<Chapter?>) -> some View {
        modifier(ChapterActions(chapter: chapter, openSource: openSource, deleting: deleting))
    }
    func chapterDeletion(_ deleting: Binding<Chapter?>) -> some View { modifier(ChapterDeletion(deleting: deleting)) }
}
