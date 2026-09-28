import Foundation
import WhispererCore

/// Model downloads from Hugging Face with progress. Writes to `<id>.part`, moves into place when complete.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var tasks: [Int: VoiceModel] = [:]
    private let lock = NSLock()

    @MainActor func start(_ m: VoiceModel) {
        let model = AppModel.shared
        guard model.downloads[m.id] == nil else { return }
        model.downloads[m.id] = 0
        let task = session.downloadTask(with: m.url)
        lock.lock(); tasks[task.taskIdentifier] = m; lock.unlock()
        task.resume()
    }

    @MainActor func cancel(_ id: String) {
        session.getAllTasks { all in
            self.lock.lock()
            let ids = self.tasks.filter { $0.value.id == id }.map(\.key)
            self.lock.unlock()
            all.filter { ids.contains($0.taskIdentifier) }.forEach { $0.cancel() }
        }
        AppModel.shared.downloads[id] = nil
    }

    private func model(for task: URLSessionTask) -> VoiceModel? {
        lock.lock(); defer { lock.unlock() }
        return tasks[task.taskIdentifier]
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let m = model(for: downloadTask) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : m.bytes
        let p = Double(totalBytesWritten) / Double(max(1, total))
        DispatchQueue.main.async { AppModel.shared.downloads[m.id] = min(0.999, p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let m = model(for: downloadTask) else { return }
        let dest = Paths().modelFile(m.id)
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var err: String?
        if code == 200 {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
            } catch { err = error.localizedDescription }
        } else { err = "HTTP \(code)" }
        DispatchQueue.main.async {
            let app = AppModel.shared
            app.downloads[m.id] = nil
            app.refreshInstalledModels()
            if let err { app.lastError = "Download of \(m.name) failed: \(err)" }
            else if !app.installedModelIDs.contains(m.id) { app.lastError = "Download of \(m.name) was incomplete." }
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let m = model(for: task) else { return }
        lock.lock(); tasks[task.taskIdentifier] = nil; lock.unlock()
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async {
            AppModel.shared.downloads[m.id] = nil
            AppModel.shared.lastError = "Download of \(m.name) failed: \(error.localizedDescription)"
        }
    }
}
