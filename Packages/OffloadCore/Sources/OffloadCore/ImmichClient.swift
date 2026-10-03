import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ImmichError: LocalizedError, Sendable {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        switch status {
        case 401: return "Immich didn't accept the API key."
        case 403: return "The API key is missing a permission: \(message)"
        case 0: return message
        default: return "Immich said \(status): \(message)"
        }
    }

    /// Turns an error response from Immich ({"message": ..., ...}) into an error.
    public static func from(status: Int, body: Data) -> ImmichError {
        var message = String(decoding: body.prefix(300), as: UTF8.self)
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let m = obj["message"] as? String { message = m }
            else if let m = obj["message"] as? [String] { message = m.joined(separator: "; ") }
        }
        return ImmichError(status: status, message: message)
    }
}

public struct CheckResult: Decodable, Sendable {
    public let id: String
    public let action: String
    public let reason: String?
    public let assetId: String?
    public let isTrashed: Bool?

    public var isNew: Bool { action == "accept" }
    public var isDuplicate: Bool { action == "reject" && reason == "duplicate" }
}

public struct UploadResponse: Decodable, Sendable {
    public let id: String
    /// "created" or "duplicate"
    public let status: String
}

public struct Album: Decodable, Sendable {
    public let id: String
    public let albumName: String
}

/// The few Immich API calls Offload makes. The upload itself isn't here: it goes
/// through the app's background session, from a body file (see MultipartBody),
/// using `uploadRequest`.
public struct ImmichClient: Sendable {
    public let api: URL
    public let apiKey: String
    private let session: URLSession

    /// `server` can be "photos.example.com", "https://photos.example.com/" or the
    /// full ".../api" address; all mean the same.
    public init(server: String, apiKey: String, session: URLSession = .shared) throws {
        guard let api = Self.apiURL(server) else {
            throw ImmichError(status: 0, message: "\"\(server)\" isn't a server address.")
        }
        self.api = api
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public static func apiURL(_ server: String) -> URL? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") {
            // Plain http for a LAN address, https for a real hostname.
            let host = s.split(separator: "/").first?.split(separator: ":").first.map(String.init) ?? s
            let local = host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
            s = (local ? "http://" : "https://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/api") { s += "/api" }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    public func url(_ path: String) -> URL {
        URL(string: api.absoluteString + path)!
    }

    func request(_ method: String, _ path: String, json: Any? = nil) throws -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 60
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// URLSession's async API isn't on every platform this builds for.
    func send(_ r: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            session.dataTask(with: r) { data, response, error in
                if let error { return c.resume(throwing: error) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data ?? Data()
                if (200 ..< 300).contains(status) { c.resume(returning: body) }
                else { c.resume(throwing: ImmichError.from(status: status, body: body)) }
            }.resume()
        }
    }

    func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: await send(request("GET", path)))
    }

    public func ping() async throws {
        _ = try await send(request("GET", "/server/ping"))
    }

    public func mediaTypes() async throws -> MediaTypes {
        struct R: Decodable { let image: [String]; let video: [String] }
        let r = try await get("/server/media-types", as: R.self)
        return MediaTypes(image: Set(r.image), video: Set(r.video))
    }

    /// Which of these (id, sha1) pairs Immich already holds, in batches of 500.
    public func check(_ items: [(id: String, sha1: String)]) async throws -> [CheckResult] {
        struct R: Decodable { let results: [CheckResult] }
        var out: [CheckResult] = []
        for start in stride(from: 0, to: items.count, by: 500) {
            let batch = items[start ..< min(start + 500, items.count)]
            let body = ["assets": batch.map { ["id": $0.id, "checksum": $0.sha1] }]
            let data = try await send(request("POST", "/assets/bulk-upload-check", json: body))
            out += try JSONDecoder().decode(R.self, from: data).results
        }
        return out
    }

    public func albums() async throws -> [Album] {
        try await get("/albums", as: [Album].self)
    }

    public func createAlbum(_ name: String, assetIds: [String]) async throws -> Album {
        let data = try await send(request("POST", "/albums", json: ["albumName": name, "assetIds": assetIds]))
        return try JSONDecoder().decode(Album.self, from: data)
    }

    public func addToAlbum(_ albumId: String, assetIds: [String]) async throws {
        _ = try await send(request("PUT", "/albums/\(albumId)/assets", json: ["ids": assetIds]))
    }

    /// Adds the assets to the album with this name, making it if there isn't one.
    /// Assets already in it are left alone, so this is safe to repeat.
    public func addToAlbum(named name: String, assetIds: [String]) async throws {
        guard !assetIds.isEmpty else { return }
        if let album = try await albums().first(where: { $0.albumName == name }) {
            try await addToAlbum(album.id, assetIds: assetIds)
        } else {
            _ = try await createAlbum(name, assetIds: assetIds)
        }
    }

    /// Checks the key works and has every permission Offload uses, by making the
    /// calls themselves (with nothing in them).
    public func verify() async throws {
        _ = try await check([])
        _ = try await albums()
    }

    /// POST /api/assets for a body file made by MultipartBody.
    public func uploadRequest(contentType: String, sha1: String) -> URLRequest {
        var r = URLRequest(url: url("/assets"))
        r.httpMethod = "POST"
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // Lets Immich answer "duplicate" before the body arrives.
        r.setValue(sha1, forHTTPHeaderField: "x-immich-checksum")
        return r
    }

    /// Reads the answer to an upload: the asset's ID, whether it was new or not.
    public static func parseUpload(status: Int, body: Data) throws -> UploadResponse {
        guard status == 200 || status == 201 else { throw ImmichError.from(status: status, body: body) }
        return try JSONDecoder().decode(UploadResponse.self, from: body)
    }
}
