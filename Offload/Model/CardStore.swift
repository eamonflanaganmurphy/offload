import Foundation
import Observation
import OffloadCore

/// What the grid shows for a file.
enum FileState: Equatable {
    case unchecked, new, inImmich, unsupported
    case queued, reading(Double), uploading(Double), uploaded, failed(String)

    var isInImmich: Bool { self == .inImmich || self == .uploaded }
    /// Worth uploading: not in Immich, and not on its way there.
    var canUpload: Bool {
        switch self {
        case .unchecked, .new: return true
        case .failed: return true
        default: return false
        }
    }
}

struct DaySection: Identifiable {
    let id: String
    let title: String
    let files: [CardFile]
}

/// The card that's plugged in: what's on it and which of it Immich already has.
@MainActor @Observable
final class CardStore {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", new = "Not in Immich", inImmich = "In Immich"
        var id: String { rawValue }
    }

    private(set) var root: URL?
    private(set) var cardName = ""
    private(set) var cardID = ""
    private(set) var files: [CardFile] = []
    private(set) var albumName: String?
    private(set) var types = MediaTypes.fallback
    private(set) var scanning = false
    private(set) var checking = false
    /// Files hashed and looked up in Immich so far.
    private(set) var checkedCount = 0
    var selection: Set<String> = []
    var error: String?

    @ObservationIgnored private var hashes: [String: String] = [:]
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    private var check: [String: FileState] = [:]
    @ObservationIgnored private let hashCache = HashCache(url: Support.dir.appendingPathComponent("hashes.json"))

    private static let bookmarkKey = "cardBookmark"

    // MARK: - Opening and closing

    /// A folder chosen in the Files picker: the card itself, or a folder on it.
    func open(_ url: URL) {
        close()
        _ = url.startAccessingSecurityScopedResource()
        root = url
        let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey])
        let volume = v?.volumeName ?? url.lastPathComponent
        cardName = url.lastPathComponent == volume ? volume : "\(volume) › \(url.lastPathComponent)"
        cardID = (v?.volumeUUIDString ?? "\(volume)-\(v?.volumeTotalCapacity ?? 0)") + ":" + url.lastPathComponent
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        Uploader.shared.attach(url, cardID: cardID)
        Task { await scan() }
    }

    /// Reopens the last card if it's still plugged in.
    func restore() {
        guard root == nil, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        let there = (try? url.checkResourceIsReachable()) == true
        url.stopAccessingSecurityScopedResource()
        if there { open(url) }
    }

    /// Back in the app: notices a card that's been taken out or put back.
    func refresh() {
        if let root, (try? root.checkResourceIsReachable()) != true {
            close()
            Uploader.shared.detach()
        } else if root == nil {
            restore()
        }
    }

    func close() {
        checkTask?.cancel()
        hashCache.save()
        root?.stopAccessingSecurityScopedResource()
        root = nil
        files = []
        check = [:]
        hashes = [:]
        selection = []
        albumName = nil
        error = nil
        checkedCount = 0
    }

    // MARK: - Reading the card

    func scan() async {
        guard let root else { return }
        scanning = true
        error = nil
        if let client = try? AppSettings.shared.client(), let t = try? await client.mediaTypes() {
            types = t
            AppSettings.shared.remember(t)
        } else {
            types = AppSettings.shared.mediaTypes
        }
        let types = self.types
        do {
            let found = try await Task.detached(priority: .userInitiated) {
                try CardScanner.scan(root, types: types)
            }.value
            guard root == self.root else { return }
            files = found
            albumName = AlbumName.forCard(found)
            hashes = [:]
            for f in found {
                if let h = hashCache[f.cacheKey] { hashes[f.rel] = h }
            }
            check = Dictionary(found.map { ($0.rel, check[$0.rel] ?? .unchecked) }, uniquingKeysWith: { a, _ in a })
            selection.formIntersection(found.map(\.rel))
        } catch {
            self.error = "Couldn't read the card: \(error.localizedDescription)"
        }
        scanning = false
        startCheck()
    }

    /// Hashes every file (newest first, so today's shots are sorted out first)
    /// and asks Immich which it already has. Hashes are remembered, so a card
    /// that's been seen before is checked in a second.
    func startCheck() {
        checkTask?.cancel()
        guard root != nil, AppSettings.shared.isConfigured else { return }
        checkTask = Task { await runCheck() }
    }

    private func runCheck() async {
        guard let root, let client = try? AppSettings.shared.client() else { return }
        checking = true
        checkedCount = 0
        error = nil
        defer {
            checking = false
            hashCache.save()
        }
        let order = files.sorted { $0.modified > $1.modified }
        await submit(order.filter { hashes[$0.rel] != nil }, client)

        var batch: [CardFile] = []
        var batchBytes: Int64 = 0
        for f in order where hashes[f.rel] == nil {
            if Task.isCancelled { return }
            let url = f.url(in: root)
            guard let h = try? await Task.detached(priority: .utility, operation: {
                try SHA1Hasher.hashFile(url)
            }).value else { continue }
            if Task.isCancelled { return }
            hashes[f.rel] = h
            hashCache[f.cacheKey] = h
            batch.append(f)
            batchBytes += f.size
            if batch.count >= 40 || batchBytes > 1 << 30 {
                await submit(batch, client)
                hashCache.save()
                batch = []
                batchBytes = 0
            }
        }
        await submit(batch, client)
    }

    private func submit(_ batch: [CardFile], _ client: ImmichClient) async {
        let items = batch.compactMap { f in hashes[f.rel].map { (id: f.rel, sha1: $0) } }
        guard !items.isEmpty else { return }
        do {
            for r in try await client.check(items) {
                check[r.id] = r.isNew ? .new : r.isDuplicate ? .inImmich : .unsupported
            }
            checkedCount += items.count
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { self.error = "Couldn't check with Immich: \(error.localizedDescription)" }
        }
    }

    // MARK: - What the views read

    func state(of f: CardFile) -> FileState {
        let up = Uploader.shared
        if let j = up.job(cardID: cardID, rel: f.rel) {
            switch j.state {
            case .waiting: return .queued
            case .reading: return .reading(f.size > 0 ? Double(j.read) / Double(f.size) : 0)
            case .uploading: return .uploading(up.fraction(j))
            case .done, .skipped: return .uploaded
            case .failed: return .failed(j.message ?? "Failed")
            }
        }
        return check[f.rel] ?? .unchecked
    }

    /// The shoot's files that aren't in Immich, including ones not checked yet:
    /// those are checked again just before they're sent.
    var uploadable: [CardFile] {
        files.filter { $0.group == .shoot && state(of: $0).canUpload }
    }

    var counts: (new: Int, inImmich: Int) {
        var n = 0, i = 0
        for f in files {
            let s = state(of: f)
            if s.isInImmich { i += 1 } else if s == .new { n += 1 }
        }
        return (n, i)
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    func sections(_ filter: Filter) -> [DaySection] {
        let shown = files.filter { f in
            switch filter {
            case .all: return true
            case .new: return !state(of: f).isInImmich
            case .inImmich: return state(of: f).isInImmich
            }
        }
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        let cal = Calendar.current
        let shoot = Dictionary(grouping: shown.filter { $0.group == .shoot }) { cal.startOfDay(for: $0.modified) }
        var out = shoot.keys.sorted(by: >).map { day in
            DaySection(id: AlbumName.day(day, cal), title: fmt.string(from: day),
                       files: shoot[day]!.sorted { ($0.modified, $0.rel) < ($1.modified, $1.rel) })
        }
        let trash = shown.filter { $0.group == .trash }
        if !trash.isEmpty {
            out.append(DaySection(id: "trash", title: "Card Trash (deleted on a Mac)",
                                  files: trash.sorted { $0.modified < $1.modified }))
        }
        return out
    }

    // MARK: - Choosing and sending

    func toggle(_ f: CardFile) {
        guard state(of: f).canUpload else { return }
        if selection.contains(f.rel) { selection.remove(f.rel) } else { selection.insert(f.rel) }
    }

    func selectable(in section: DaySection) -> [String] {
        section.files.filter { state(of: $0).canUpload }.map(\.rel)
    }

    /// Uploads the selection, or every new file in the shoot if nothing's selected.
    func upload() {
        guard let root else { return }
        let chosen = selection.isEmpty ? uploadable : files.filter { selection.contains($0.rel) && state(of: $0).canUpload }
        guard !chosen.isEmpty else { return }
        let album = AppSettings.shared.addToAlbum ? albumName : nil
        // Oldest first, as the camera took them.
        let ordered = chosen.sorted { ($0.modified, $0.rel) < ($1.modified, $1.rel) }
        Uploader.shared.enqueue(ordered, cardID: cardID, root: root, album: album, hashes: hashes)
        selection = []
    }
}
