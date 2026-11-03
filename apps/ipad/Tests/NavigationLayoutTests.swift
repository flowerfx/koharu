import XCTest
import SwiftUI
@testable import KoharuPad

final class NavigationLayoutTests: XCTestCase {
    @MainActor func testTabBarRemainsVisibleAndHittableWithCreditAndProgress() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("The floating bottom tab bar is an iPhone layout; iPad uses adaptive top tabs.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MangaLibrary(disk: try LibraryDisk(root: root))
        let language = AppLocalization.shared.language
        AppLocalization.shared.language = .englishUS
        defer { AppLocalization.shared.language = language }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: RootScreen(refreshConfiguration: {})
            .environment(library).tint(.pink).preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        let tabs = try XCTUnwrap(tabController(in: host))
        var frames: [[String: Any]] = []
        for index in 0..<4 {
            tabs.selectedIndex = index
            let selected = try XCTUnwrap(tabs.viewControllers?[index])
            tabs.delegate?.tabBarController?(tabs, didSelect: selected)
            for working in [false, true] {
                library.busy = working
                library.progress = 0.4
                library.status = "Translating a chapter with a long title — page 28 of 69"
                try await Task.sleep(for: .milliseconds(350))
                host.view.layoutIfNeeded()
                XCTAssertEqual(tabs.selectedIndex, index)
                let bar = tabs.tabBar
                let frame = bar.convert(bar.bounds, to: window)
                XCTAssertFalse(bar.isHidden)
                XCTAssertGreaterThan(bar.alpha, 0.9)
                XCTAssertTrue(window.bounds.contains(frame), "Tab bar must stay inside the window: \(frame)")
                let count = try XCTUnwrap(bar.items).count
                XCTAssertEqual(count, 4)
                for item in 0..<count {
                    let point = CGPoint(x: frame.minX + frame.width * (CGFloat(item) + 0.5) / CGFloat(count), y: frame.midY)
                    let hit = try XCTUnwrap(window.hitTest(point, with: nil))
                    XCTAssertTrue(hit === bar || hit.isDescendant(of: bar), "Tab \(item) covered by \(type(of: hit)) at \(point)")
                }
                let name = "navigation-tab-\(index)-\(working ? "processing" : "idle")"
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try XCTUnwrap(image.pngData()).write(to: documents.appendingPathComponent(name + ".png"))
                frames.append(["tab": index, "processing": working, "tab_bar": "\(frame)", "window": "\(window.bounds)"])
            }
        }
        library.busy = false
        let data = try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try data.write(to: documents.appendingPathComponent("navigation-layout-frames.json"))
    }

    @MainActor private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = tabController(in: child) { return tabs }
        }
        return nil
    }
}
