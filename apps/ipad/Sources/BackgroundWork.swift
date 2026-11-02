import Foundation
import UIKit

// iOS denies GPU command submission to background apps, so local Metal,
// Core ML and Vision jobs fail unpredictably if they keep running. When the
// scene goes to the background the job is cancelled cooperatively; a short
// background task lets cancellation, page saves and credit settlement finish.
extension MangaLibrary {
    func enterBackground() {
        flushReadPositions()
        guard busy else { return }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Koharu work") { [weak self] in
                // Called on the main thread; the task must end before returning.
                MainActor.assumeIsolated { self?.backgroundTimeExpired() }
            }
        }
        if activeJobUsesGPU { stopForBackground() }
    }
    private func stopForBackground() {
        guard busy, let task = activeTask, !task.isCancelled else { return }
        error = L("Work was stopped because the app moved to the background. Pages and images already finished are kept. Keep the app open while translating or generating images.")
        task.cancel()
    }
    private func backgroundTimeExpired() {
        stopForBackground()
        endBackgroundWork()
    }
    func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // Reading position is saved after the reader settles, not on every
    // slider tick, and always before the app leaves the foreground.
    func setReadPage(_ id: UUID, _ page: Int) {
        guard let index = chapters.firstIndex(where: { $0.id == id }), chapters[index].readPage != page else { return }
        chapters[index].readPage = page
        readPositionSaves[id]?.cancel()
        readPositionSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveReadPosition(id)
        }
    }
    func flushReadPositions() {
        for (id, task) in readPositionSaves {
            task.cancel()
            saveReadPosition(id)
        }
    }
    private func saveReadPosition(_ id: UUID) {
        readPositionSaves[id] = nil
        guard let chapter = chapters.first(where: { $0.id == id }) else { return }
        do { try disk.save(chapter, recordUndo: false) } catch { self.error = error.localizedDescription }
    }
}
