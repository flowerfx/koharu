import XCTest
import SwiftUI
@testable import KoharuPad

private actor ChapterRPC {
    let disk: LibraryDisk
    let chapterID: UUID
    let missingSource: URL
    var submissions = 0
    var request: [String: Any] = [:]
    init(disk: LibraryDisk, chapterID: UUID, missingSource: URL) { self.disk = disk; self.chapterID = chapterID; self.missingSource = missingSource }
    func call(_ name: String, _ body: String) throws -> String {
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        if name == "ai_generate" {
            submissions += 1; request = input
            let chapter = try disk.load(Chapter.self, disk.chapterURL(chapterID).appendingPathComponent("chapter.json"))
            XCTAssertEqual(chapter.pages.count, 2)
            XCTAssertTrue(chapter.pages.allSatisfy { $0.ocrSignature != nil && !$0.segments.isEmpty }, "Every page must finish OCR before the single chapter submission")
        }
        let count = request["count"] as? Int ?? 0
        var value: [String: Any] = ["request_id":request["request_id"] ?? "", "reservation_id":request["reservation_id"] ?? "", "status":name == "ai_generate" ? "queued" : "succeeded"]
        if name == "ai_result" {
            value["result"] = ["provider":"anthropic","model":"fixture","output":["translations":(0..<count).reversed().map { ["id":$0,"text":"Translation \($0)"] as [String:Any] }]]
            // Simulate a render failure after the complete chapter response.
            try FileManager.default.moveItem(at: missingSource, to: missingSource.appendingPathExtension("held"))
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    func count() -> Int { submissions }
}

final class ChapterTranslationChecks: XCTestCase {
    @MainActor func testAllOCRBeforeSingleSubmissionAndRenderFailureResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        var chapter = Chapter(title: "Chapter pipeline check", sourceURL: "imported://check", target: "en-US", pages: [])
        try FileManager.default.createDirectory(at: disk.chapterURL(chapter.id), withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        for (index,text) in ["こんにちは", "ありがとう"].enumerated() {
            let image = UIGraphicsImageRenderer(size: CGSize(width:512,height:512), format:format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:512,height:512))
                (text as NSString).draw(at:CGPoint(x:90,y:200),withAttributes:[.font:UIFont.systemFont(ofSize:40),.foregroundColor:UIColor.black])
            }
            let file = "source-\(index).png"
            try XCTUnwrap(image.pngData()).write(to: disk.pageURL(chapter.id,file))
            chapter.pages.append(MangaPage(source:"imported://\(index)",original:file))
        }
        let missing = disk.pageURL(chapter.id,chapter.pages[1].original)
        let fixture = ChapterRPC(disk:disk,chapterID:chapter.id,missingSource:missing)
        let backend = BackendAI(rpc:{ try await fixture.call($0,$1) },pause:{})
        let library = MangaLibrary(disk:disk,translator:TranslationEngine(backend:backend))
        var settings = Preferences(); settings.provider = .backend; settings.target = "en-US"; settings.ocrModel = nil; settings.inpaint = false
        try library.update(chapter)
        let reservation = UUID().uuidString
        do { try await library.processChapter(chapter.id,config:settings,ticket:reservation,force:false); XCTFail("The second render should fail") }
        catch { XCTAssertFalse(FileManager.default.fileExists(atPath:missing.path)) }
        let first = try XCTUnwrap(library.chapters.first)
        XCTAssertNotNil(first.pages[0].rendered)
        XCTAssertTrue(first.pages.allSatisfy { $0.translationFingerprint != nil && $0.segments.allSatisfy { $0.text != nil } })
        try FileManager.default.moveItem(at:missing.appendingPathExtension("held"),to:missing)
        try await library.processChapter(chapter.id,config:settings,ticket:reservation,force:false)
        let submissions = await fixture.count(); XCTAssertEqual(submissions,1,"Resume rendering without paying for another translation")
        let saved = try XCTUnwrap(disk.chapters().first)
        XCTAssertTrue(saved.pages.allSatisfy { $0.rendered.map { FileManager.default.fileExists(atPath:disk.pageURL(saved.id,$0).path) } == true })
    }

    @MainActor func testProcessingIndicatorLongLabels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let library = MangaLibrary(disk:try LibraryDisk(root:root))
        let language = AppLocalization.shared.language
        defer { AppLocalization.shared.language = language }
        AppLocalization.shared.language = .german
        library.progress = 0.5
        library.status = String(format: L("Translating chapter · %lld/%lld regions · batch %lld/%lld"),Int64(1050),Int64(2000),Int64(11),Int64(20))
        let controller = UIHostingController(rootView:ChapterProcessingIndicator().environment(library))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene:scene); window.frame = CGRect(x:0,y:0,width:390,height:220)
        window.rootViewController = controller; window.makeKeyAndVisible(); controller.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(250))
        let image = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true) }
        let documents = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        try XCTUnwrap(image.pngData()).write(to:documents.appendingPathComponent("chapter-processing-indicator.png"))
        window.isHidden = true
    }
}
