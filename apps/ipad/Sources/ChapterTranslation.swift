import Foundation

struct ChapterTranslationPlan {
    struct Target {
        let pageID: UUID
        let segmentID: Int
        let source: String
    }
    let targets: [Target]
    init(pages: [MangaPage]) throws {
        var targets: [Target] = []
        for page in pages {
            guard Set(page.segments.map(\.id)).count == page.segments.count else {
                throw AppError.message(L("The model returned missing, duplicate or invalid segment IDs"))
            }
            targets += page.segments.filter { !$0.edited }.map { Target(pageID: page.id, segmentID: $0.id, source: $0.source) }
        }
        self.targets = targets
    }
    func apply(_ translations: [String], to pages: inout [MangaPage], fingerprint: String) throws {
        guard translations.count == targets.count else { throw AppError.message(L("The model omitted a translation")) }
        var updated = pages
        for (target, text) in zip(targets, translations) {
            guard let page = updated.firstIndex(where: { $0.id == target.pageID }),
                  let segment = updated[page].segments.firstIndex(where: { $0.id == target.segmentID }),
                  !updated[page].segments[segment].edited, updated[page].segments[segment].source == target.source else {
                throw AppError.message(L("The model returned missing, duplicate or invalid segment IDs"))
            }
            updated[page].segments[segment].text = text
            updated[page].translationFingerprint = fingerprint
            updated[page].fingerprint = nil
        }
        pages = updated
    }
}
