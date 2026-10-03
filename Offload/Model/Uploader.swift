import Foundation
import Observation
import OffloadCore
import UIKit

/// One file on its way to Immich.
struct UploadJob: Codable, Identifiable {
    enum State: String, Codable {
        case waiting
        /// Being copied off the card into an upload body, and hashed.
        case reading
        /// Handed to the background session.
        case uploading
        case done
        /// Immich already had it.
        case skipped
        case failed
    }

    var id = UUID()
    let cardID: String
    let file: CardFile
    /// nil for files from the card's trash, and when albums are turned off.
    let album: String?
    var state = State.waiting
    var sha1: String?
    var assetId: String?
    var message: String?
    var contentType: String?
    var bodySize: Int64 = 0
    var read: Int64 = 0
    var attempts = 0
    var addedToAlbum = false

    var isActive: Bool { state == .waiting || state == .reading || state == .uploading }
    var bodyURL: URL { Support.bodies.appendingPathComponent(id.uuidString) }
}

/// Copies files off the card and uploads them with a background URLSession,
/// which iOS carries on with when Offload is closed or the phone is locked.
///
/// A background session can only upload from a file, so each photo is first
/// copied into an upload body (hashed on the way). Only `readAhead` bytes are
/// copied ahead of the uploads, so the phone never holds more than that of the
/// card at once; each body is deleted as soon as Immich has the file.
@MainActor @Observable
final class Uploader {
    static let shared = Uploader()
    static let sessionID = "me.eamonmurphy.offload.upload"
    static let readAhead: Int64 = 1_500_000_000
    static let maxQueued = 8

    private(set) var jobs: [UploadJob] = []
    /// Why the queue has stopped, e.g. the card was taken out.
    private(set) var paused: String?
    /// Bumped a few times a second while bytes are going out, for progress views.
    private(set) var tick = 0

    /// Called by the app delegate when iOS wakes Offload for the session.
    @ObservationIgnored var backgroundEventsDone: (() -> Void)?

    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var rootCardID: String?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var index: [UUID: Int] = [:]
    @ObservationIgnored private var byFile: [String: Int] = [:]
    @ObservationIgnored private var sent: [UUID: Int64] = [:]
    @ObservationIgnored private var sentChanged = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var stopReading = StopFlag()
    @ObservationIgnored private var flushingAlbums = false
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var restored = false

    private static var jobsFile: URL { Support.dir.appendingPathComponent("jobs.json") }

    private init() {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 3 * 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: SessionRelay(), delegateQueue: queue)
    }

    // MARK: - What the views read

    var isRunning: Bool { jobs.contains { $0.isActive } }

    func job(cardID: String, rel: String) -> UploadJob? {
        guard let i = byFile[cardID + "|" + rel], i < jobs.count else { return nil }
        return jobs[i]
    }

    /// How much of a job's body has gone out, 0...1.
    func fraction(_ job: UploadJob) -> Double {
        _ = tick
        switch job.state {
        case .done, .skipped: return 1
        case .uploading: return job.bodySize > 0 ? min(1, Double(sent[job.id] ?? 0) / Double(job.bodySize)) : 0
        default: return 0
        }
    }

    struct Totals {
        var files = 0, finished = 0, failed = 0
        var bytes: Int64 = 0, doneBytes: Int64 = 0
        var reading: String?
    }

    var totals: Totals {
        var t = Totals()
        for j in jobs {
            t.files += 1
            t.bytes += j.file.size
            switch j.state {
            case .done, .skipped: t.finished += 1; t.doneBytes += j.file.size
            case .failed: t.failed += 1
            case .uploading: t.doneBytes += Int64(fraction(j) * Double(j.file.size))
            case .reading: t.reading = j.file.name
            case .waiting: break
            }
        }
        return t
    }

    // MARK: - Starting and stopping

    /// Called at launch: picks the queue back up and reconnects to the session,
    /// which then delivers whatever finished while Offload wasn't running.
    func restore() {
        guard !restored else { return }
        restored = true
        if let data = try? Data(contentsOf: Self.jobsFile),
           let saved = try? JSONDecoder().decode([UploadJob].self, from: data) {
            jobs = saved
        }
        for i in jobs.indices where jobs[i].state == .reading {
            // Killed mid-copy: start that file again.
            jobs[i].state = .waiting
            try? FileManager.default.removeItem(at: jobs[i].bodyURL)
        }
        reindex()
        removeStrayBodies()
        // An upload the session has no record of, that never reported back,
        // goes again. Give the session a moment to deliver what it has first.
        Task {
            try? await Task.sleep(for: .seconds(5))
            let live = Set(await session.allTasks.compactMap(\.taskDescription))
            requeueLost(live)
        }
        updateRunning()
        flushAlbums()
    }

    /// Queues files from the card at `root`. Finished jobs from earlier runs are
    /// cleared out first, so the progress bar is about this batch.
    func enqueue(_ files: [CardFile], cardID: String, root: URL, album: String?, hashes: [String: String]) {
        if !isRunning {
            // Keep any whose album add hasn't happened yet.
            jobs.removeAll { !$0.isActive && ($0.addedToAlbum || $0.album == nil || $0.assetId == nil) }
            reindex()
        }
        attach(root, cardID: cardID)
        for f in files {
            if let j = job(cardID: cardID, rel: f.rel), j.isActive || j.state == .done || j.state == .skipped { continue }
            jobs.removeAll { $0.cardID == cardID && $0.file.rel == f.rel }
            var job = UploadJob(cardID: cardID, file: f, album: f.group == .shoot ? album : nil)
            job.sha1 = hashes[f.rel]
            jobs.append(job)
            reindex()
        }
        paused = nil
        save()
        updateRunning()
        pump()
    }

    /// The card is readable at `root`. Carries on with any of its files still waiting.
    func attach(_ root: URL, cardID: String) {
        guard self.root != root || rootCardID != cardID else { return }
        if let old = self.root { old.stopAccessingSecurityScopedResource() }
        _ = root.startAccessingSecurityScopedResource()
        self.root = root
        rootCardID = cardID
        if paused != nil, jobs.contains(where: { $0.cardID == cardID && $0.state == .waiting }) {
            paused = nil
            pump()
        }
    }

    /// The card is gone. Uploads already copied off it carry on.
    func detach() {
        root?.stopAccessingSecurityScopedResource()
        root = nil
        rootCardID = nil
    }

    /// Cancels everything not yet in Immich and forgets it.
    func stop() {
        stopReading.set()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        for j in jobs where j.isActive {
            try? FileManager.default.removeItem(at: j.bodyURL)
        }
        jobs.removeAll { $0.isActive }
        reindex()
        paused = nil
        save()
        updateRunning()
        flushAlbums()
    }

    func retryFailed() {
        for i in jobs.indices where jobs[i].state == .failed {
            jobs[i].state = .waiting
            jobs[i].attempts = 0
            jobs[i].message = nil
        }
        paused = nil
        save()
        updateRunning()
        pump()
    }

    // MARK: - The queue

    private func pump() {
        guard paused == nil, !reading else { return }
        let uploading = jobs.filter { $0.state == .uploading }
        guard let i = jobs.firstIndex(where: { $0.state == .waiting }) else {
            if uploading.isEmpty { finished() }
            return
        }
        guard let root, rootCardID == jobs[i].cardID else {
            paused = "Plug the card back in and choose it in Offload to finish."
            return
        }
        let inFlight = uploading.reduce(Int64(0)) { $0 + $1.bodySize }
        if !uploading.isEmpty && (inFlight + jobs[i].file.size > Self.readAhead || uploading.count >= Self.maxQueued) {
            return
        }
        read(jobs[i], from: root)
    }

    /// Copies one file off the card into an upload body, hashing it on the way.
    private func read(_ job: UploadJob, from root: URL) {
        reading = true
        holdBackgroundTime()
        set(job.id) { $0.state = .reading; $0.read = 0 }
        let flag = StopFlag()
        stopReading = flag
        let id = job.id, file = job.file, dest = job.bodyURL, source = file.url(in: root)
        Task {
            let body = MultipartBody()
            do {
                let (sha, size) = try await Task.detached(priority: .userInitiated) {
                    try body.write(file, from: source, to: dest,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                   isCancelled: { flag.isSet }) { n in
                        Task { @MainActor in Uploader.shared.set(id) { $0.read = n } }
                    }
                }.value
                await didRead(id, sha: sha, size: size, contentType: body.contentType)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                if !flag.isSet { readFailed(id, error) }
            }
            reading = false
            releaseBackgroundTime()
            pump()
        }
    }

    private func didRead(_ id: UUID, sha: String, size: Int64, contentType: String) async {
        guard index[id] != nil else {
            // Stopped while it was being read.
            try? FileManager.default.removeItem(at: Support.bodies.appendingPathComponent(id.uuidString))
            return
        }
        set(id) { $0.sha1 = sha; $0.bodySize = size; $0.contentType = contentType }
        // Immich may have it already, from the home pipeline or another phone,
        // if it wasn't checked before it was queued. No need to send it then.
        if let j = jobs[safe: index[id]], let client = try? AppSettings.shared.client(),
           let r = try? await client.check([(id: j.file.rel, sha1: sha)]).first, r.isDuplicate {
            finish(id, assetId: r.assetId, skipped: true)
            return
        }
        startUpload(id)
    }

    private func startUpload(_ id: UUID) {
        guard let j = jobs[safe: index[id]], let sha = j.sha1, let type = j.contentType else { return }
        guard let client = try? AppSettings.shared.client() else {
            set(id) { $0.state = .failed; $0.message = "Set up the server in Settings." }
            return
        }
        let task = session.uploadTask(with: client.uploadRequest(contentType: type, sha1: sha), fromFile: j.bodyURL)
        task.taskDescription = id.uuidString
        task.countOfBytesClientExpectsToSend = j.bodySize
        task.countOfBytesClientExpectsToReceive = 200
        sent[id] = 0
        set(id) { $0.state = .uploading }
        save()
        task.resume()
    }

    private func readFailed(_ id: UUID, _ error: Error) {
        if let root, (try? root.checkResourceIsReachable()) != true {
            set(id) { $0.state = .waiting }
            detach()
            paused = "Can't read the card. Plug it back in and choose it in Offload to finish."
        } else {
            set(id) { $0.state = .failed; $0.message = "Couldn't read it from the card: \(error.localizedDescription)" }
        }
        save()
    }

    private func finish(_ id: UUID, assetId: String?, skipped: Bool) {
        set(id) {
            $0.state = skipped ? .skipped : .done
            $0.assetId = assetId
            $0.message = nil
        }
        sent[id] = nil
        try? FileManager.default.removeItem(at: Support.bodies.appendingPathComponent(id.uuidString))
        save()
        let waitingForAlbum = jobs.filter { $0.album != nil && $0.assetId != nil && !$0.addedToAlbum }.count
        if waitingForAlbum >= 25 { flushAlbums() }
    }

    private func finished() {
        updateRunning()
        flushAlbums()
        releaseBackgroundTime()
    }

    /// Adds finished uploads to their albums, a batch at a time. Kept on the
    /// jobs, so it's picked up again if Offload is closed before it happens.
    private func flushAlbums() {
        guard !flushingAlbums, AppSettings.shared.isConfigured else { return }
        var byAlbum: [String: [UUID]] = [:]
        for j in jobs where !j.addedToAlbum && j.assetId != nil {
            if let album = j.album { byAlbum[album, default: []].append(j.id) }
        }
        guard !byAlbum.isEmpty, let client = try? AppSettings.shared.client() else { return }
        flushingAlbums = true
        Task {
            for (album, ids) in byAlbum {
                let assets = ids.compactMap { jobs[safe: index[$0]]?.assetId }
                if (try? await client.addToAlbum(named: album, assetIds: assets)) != nil {
                    for id in ids { set(id) { $0.addedToAlbum = true } }
                }
            }
            flushingAlbums = false
            save()
        }
    }

    // MARK: - From the session (via SessionRelay)

    func didSend(_ id: String?, _ bytes: Int64) {
        guard let id, let uuid = UUID(uuidString: id) else { return }
        sent[uuid] = bytes
        sentChanged = true
    }

    func didComplete(_ id: String?, status: Int, body: Data, error: Error?) {
        guard let id, let uuid = UUID(uuidString: id), let j = jobs[safe: index[uuid]],
              j.state == .uploading else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            retryOrFail(uuid, error.localizedDescription)
        } else if status >= 500 {
            retryOrFail(uuid, ImmichError.from(status: status, body: body).localizedDescription)
        } else {
            do {
                let r = try ImmichClient.parseUpload(status: status, body: body)
                finish(uuid, assetId: r.id, skipped: r.status == "duplicate")
            } catch {
                set(uuid) { $0.state = .failed; $0.message = error.localizedDescription }
                try? FileManager.default.removeItem(at: j.bodyURL)
                save()
            }
        }
        pump()
    }

    /// A dropped connection or a busy server: go again with the same body, a
    /// couple of times, before giving up on the file.
    private func retryOrFail(_ id: UUID, _ message: String) {
        set(id) { $0.attempts += 1 }
        guard let j = jobs[safe: index[id]] else { return }
        if j.attempts < 3, FileManager.default.fileExists(atPath: j.bodyURL.path) {
            Task {
                try? await Task.sleep(for: .seconds(5 * j.attempts))
                if jobs[safe: index[id]]?.state == .uploading { startUpload(id) }
            }
        } else {
            set(id) { $0.state = .failed; $0.message = message }
            try? FileManager.default.removeItem(at: j.bodyURL)
            save()
        }
    }

    func backgroundEventsFinished() {
        backgroundEventsDone?()
        backgroundEventsDone = nil
    }

    private func requeueLost(_ live: Set<String>) {
        var changed = false
        for i in jobs.indices where jobs[i].state == .uploading && !live.contains(jobs[i].id.uuidString) {
            if FileManager.default.fileExists(atPath: jobs[i].bodyURL.path) {
                startUpload(jobs[i].id)
            } else {
                jobs[i].state = .waiting
            }
            changed = true
        }
        if changed { save(); pump() }
    }

    // MARK: - Housekeeping

    private func set(_ id: UUID, _ change: (inout UploadJob) -> Void) {
        guard let i = index[id], i < jobs.count else { return }
        change(&jobs[i])
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($1.id, $0) })
        byFile = Dictionary(jobs.enumerated().map { ($1.cardID + "|" + $1.file.rel, $0) }, uniquingKeysWith: { $1 })
    }

    private func save() {
        try? JSONEncoder().encode(jobs).write(to: Self.jobsFile, options: .atomic)
    }

    private func removeStrayBodies() {
        let keep = Set(jobs.filter(\.isActive).map(\.id.uuidString))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Support.bodies.path)) ?? []
        for f in files where !keep.contains(f) {
            try? FileManager.default.removeItem(at: Support.bodies.appendingPathComponent(f))
        }
    }

    /// Keeps the screen on while uploading (if wanted), and the progress ticking.
    func updateRunning() {
        let running = isRunning
        UIApplication.shared.isIdleTimerDisabled = running && AppSettings.shared.keepAwake
        if running, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let u = Uploader.shared
                    if u.sentChanged { u.sentChanged = false; u.tick += 1 }
                }
            }
        } else if !running {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Reading a file off the card has to finish even if Offload is put away
    /// halfway through; iOS gives it a little while.
    private func holdBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Read from card") {
            MainActor.assumeIsolated { Uploader.shared.releaseBackgroundTime() }
        }
    }

    private func releaseBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Tells a copy in progress to stop. Read from the copying thread.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// The session's delegate. Collects each upload's response (the delegate queue
/// is serial, so no locking) and hands finished uploads to the Uploader.
final class SessionRelay: NSObject, URLSessionDataDelegate {
    private var responses: [Int: Data] = [:]

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let id = task.taskDescription
        Task { @MainActor in Uploader.shared.didSend(id, totalBytesSent) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responses[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let body = responses.removeValue(forKey: task.taskIdentifier) ?? Data()
        Task { @MainActor in Uploader.shared.didComplete(id, status: status, body: body, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in Uploader.shared.backgroundEventsFinished() }
    }
}

extension Array {
    subscript(safe i: Int?) -> Element? {
        guard let i, indices.contains(i) else { return nil }
        return self[i]
    }
}
