import Foundation
import Observation
import OffloadCore
import Security

/// Where Immich is and how to sign in. The key lives in the Keychain; the rest
/// in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    var apiKey: String {
        didSet { Keychain.set(apiKey, for: "apiKey") }
    }
    /// Put a card's shoot in an "SD import <dates>" album, as the home pipeline does.
    var addToAlbum: Bool {
        didSet { UserDefaults.standard.set(addToAlbum, forKey: "addToAlbum") }
    }
    /// The album to use instead; blank names it after the card's dates.
    var albumName: String {
        didSet { UserDefaults.standard.set(albumName, forKey: "albumName") }
    }
    /// Only send uploads over Wi-Fi. On mobile data they wait, queued.
    var wifiOnly: Bool {
        didSet {
            UserDefaults.standard.set(wifiOnly, forKey: "wifiOnly")
            if wifiOnly != oldValue { Uploader.shared.networkRuleChanged() }
        }
    }
    var keepAwake: Bool {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake") }
    }

    /// Set when a setup link has just filled in the server and key.
    var setupMessage: String?

    private init() {
        let d = UserDefaults.standard
        server = d.string(forKey: "server") ?? "https://photos.eamonmurphy.me"
        apiKey = Keychain.get("apiKey") ?? ""
        addToAlbum = d.object(forKey: "addToAlbum") as? Bool ?? true
        albumName = d.string(forKey: "albumName") ?? ""
        wifiOnly = d.object(forKey: "wifiOnly") as? Bool ?? false
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && ImmichClient.apiURL(server) != nil
    }

    func client() throws -> ImmichClient {
        try ImmichClient(server: server, apiKey: apiKey)
    }

    /// The album a card's shoot goes into: the one named in Settings, or the
    /// card's dates one. nil with albums turned off.
    func album(dated: String?) -> String? {
        guard addToAlbum else { return nil }
        let name = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? dated : name
    }

    /// The last media types Immich reported, or the built-in list.
    var mediaTypes: MediaTypes {
        guard let data = UserDefaults.standard.data(forKey: "mediaTypes"),
              let types = try? JSONDecoder().decode(MediaTypes.self, from: data) else { return .fallback }
        return types
    }

    func remember(_ types: MediaTypes) {
        UserDefaults.standard.set(try? JSONEncoder().encode(types), forKey: "mediaTypes")
    }

    /// offload://setup?server=https://photos.example.com&key=... fills both in,
    /// so the key never has to be typed on the phone.
    func handle(_ url: URL) {
        guard url.scheme == "offload", url.host == "setup",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        if let s = items.first(where: { $0.name == "server" })?.value, !s.isEmpty { server = s }
        if let k = items.first(where: { $0.name == "key" })?.value, !k.isEmpty { apiKey = k }
        setupMessage = "Connected to \(ImmichClient.apiURL(server)?.host ?? server)."
    }
}

enum Keychain {
    static let service = "me.eamonmurphy.offload"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        // Uploads finish in the background, sometimes with the phone locked.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Files the app keeps for itself.
enum Support {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Upload bodies waiting for the background session. Not in Caches, which
    /// iOS may empty while an upload is still queued, and not backed up.
    static let bodies: URL = {
        var d = dir.appendingPathComponent("Uploading", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? d.setResourceValues(v)
        return d
    }()
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
