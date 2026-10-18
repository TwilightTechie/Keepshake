import Foundation
import Combine

/// Uses one background file upload at a time; files remain the source of truth.
final class Uploader: NSObject, ObservableObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    static let sessionID = "KeepsakeRawGateway.uploads.v1"
    @Published var status = "Set an HTTPS upload URL and token"
    @Published var pendingCount = 0
    @Published var lastUploaded = UserDefaults.standard.string(forKey: "lastUploaded") ?? "Never"
    @Published var busy = false
    var completionHandler: (() -> Void)?
    private let store: ChunkStore
    private let settings: Settings
    private var responses: [Int: Data] = [:]
    private var timer: Timer?
    private var initialized = false
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(store: ChunkStore, settings: Settings) {
        self.store = store; self.settings = settings
        super.init()
        // Reattach existing system-owned tasks before scheduling new ones.
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                self.busy = !tasks.isEmpty
                self.initialized = true
                if self.busy { self.status = "Resuming background upload" }
                self.pump()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pump() }
    }

    private func retryURL(_ file: URL) -> URL { file.appendingPathExtension("retry") }
    private func retry(_ file: URL) -> RetryState {
        guard let data = try? Data(contentsOf: retryURL(file)),
              let state = try? JSONDecoder().decode(RetryState.self, from: data) else { return RetryState() }
        return state
    }

    func retryNow() {
        do {
            for file in try store.pending() {
                let url = retryURL(file)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            pump()
        } catch { status = error.localizedDescription }
    }

    func pump() {
        do {
            let files = try store.pending()
            pendingCount = files.count
            guard initialized && !busy else { return }
            guard settings.uploadsEnabled else { status = "Uploads paused — files retained locally"; return }
            guard !files.isEmpty else { status = "Queue empty"; return }
            guard let url = settings.uploadURL, !settings.token.isEmpty else {
                status = "Queued locally — configure HTTPS URL and token"; return
            }
            guard let file = files.first(where: { retry($0).nextAttempt <= Date() }) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
            request.setValue(try ChunkStore.checksum(file), forHTTPHeaderField: "X-Content-SHA256")
            request.setValue(file.deletingPathExtension().lastPathComponent, forHTTPHeaderField: "Idempotency-Key")
            request.allowsCellularAccess = !settings.wifiOnly
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = file.lastPathComponent
            busy = true
            status = "Uploading \(file.deletingPathExtension().lastPathComponent.prefix(8))…"
            task.resume()
        } catch { status = "Queue error: \(error.localizedDescription)" }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var body = responses[dataTask.taskIdentifier] ?? Data()
        if body.count + data.count <= 65536 { body.append(data) }
        else { dataTask.cancel() }
        responses[dataTask.taskIdentifier] = body
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Configure the actual endpoint; never forward credentials via redirect.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responses.removeValue(forKey: task.taskIdentifier) ?? Data()
        defer { busy = false; pump() }
        guard let name = task.taskDescription, name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasSuffix(".jsonl") else { status = "Unknown upload task; local files retained"; return }
        let file = store.directory.appendingPathComponent(name)
        let id = file.deletingPathExtension().lastPathComponent
        do {
            let hash = try ChunkStore.checksum(file)
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil && (200...299).contains(code) && UploadAck.validates(body, id: id, checksum: hash) {
                try FileManager.default.removeItem(at: file)
                if FileManager.default.fileExists(atPath: retryURL(file).path) {
                    try FileManager.default.removeItem(at: retryURL(file))
                }
                lastUploaded = ChunkStore.timestamp(Date())
                UserDefaults.standard.set(lastUploaded, forKey: "lastUploaded")
                status = "Server confirmed storage"
            } else {
                var state = retry(file)
                state.failed()
                try JSONEncoder().encode(state).write(to: retryURL(file), options: .atomic)
                status = "Retained for retry (\(error?.localizedDescription ?? "HTTP \(code), missing or invalid storage acknowledgment"))"
            }
        } catch { status = "Upload bookkeeping error: \(error.localizedDescription). File retained if present." }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = completionHandler
        completionHandler = nil
        handler?()
    }
}
