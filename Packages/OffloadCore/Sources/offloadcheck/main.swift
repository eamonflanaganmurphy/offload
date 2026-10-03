import Foundation
import OffloadCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// offloadcheck: runs the app's scanner, hashing and Immich check against a
// folder (a card, or a copy of one), and optionally uploads, with the exact body
// the app sends. For trying things without building the app.
//
//   IMMICH_URL=https://photos.example.com IMMICH_API_KEY=... \
//     offloadcheck /path/to/card [--upload N] [--album]

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first(where: { !$0.hasPrefix("--") && Int($0) == nil }) else {
    fail("usage: offloadcheck <folder> [--upload N] [--album]")
}
let uploadCount = args.firstIndex(of: "--upload").flatMap { Int(args[safe: $0 + 1] ?? "") } ?? 0
let useAlbum = args.contains("--album")
let env = ProcessInfo.processInfo.environment
guard let server = env["IMMICH_URL"], let key = env["IMMICH_API_KEY"] else {
    fail("set IMMICH_URL and IMMICH_API_KEY")
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

func size(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

let root = URL(fileURLWithPath: path)
let client = try ImmichClient(server: server, apiKey: key)
print("server : \(client.api.absoluteString)")
try await client.verify()
print("api key: ok (upload, albums)")
let types = (try? await client.mediaTypes()) ?? .fallback
print("types  : \(types.image.count) image, \(types.video.count) video")

let files = try CardScanner.scan(root, types: types)
let shoot = files.filter { $0.group == .shoot }
print("card   : \(files.count) files, \(size(files.reduce(0) { $0 + $1.size })), \(files.count - shoot.count) in .Trashes")
let album = AlbumName.forCard(files)
print("album  : \(album ?? "-")")

var sha: [String: String] = [:]
for f in files { sha[f.rel] = try SHA1Hasher.hashFile(f.url(in: root)) }
let results = try await client.check(files.map { ($0.rel, sha[$0.rel]!) })
var new: [CardFile] = []
for r in results {
    let state = r.isNew ? "new" : r.isDuplicate ? "in immich \(r.assetId ?? "")" : "rejected (\(r.reason ?? "?"))"
    print("  \(r.id)  \(sha[r.id]!.prefix(10))  \(state)")
    if r.isNew, let f = files.first(where: { $0.rel == r.id }) { new.append(f) }
}
print("\(new.count) new, \(results.filter(\.isDuplicate).count) already in Immich")

guard uploadCount > 0 else { exit(0) }
var uploaded: [String] = []
let tmp = FileManager.default.temporaryDirectory
for f in new.prefix(uploadCount) {
    let body = MultipartBody()
    let dest = tmp.appendingPathComponent("offload-\(UUID().uuidString).body")
    let (hash, bodySize) = try body.write(f, from: f.url(in: root), to: dest)
    defer { try? FileManager.default.removeItem(at: dest) }
    let req = client.uploadRequest(contentType: body.contentType, sha1: hash)
    let (data, status): (Data, Int) = try await withCheckedThrowingContinuation { c in
        URLSession.shared.uploadTask(with: req, fromFile: dest) { d, resp, err in
            if let err { return c.resume(throwing: err) }
            c.resume(returning: (d ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0))
        }.resume()
    }
    let r = try ImmichClient.parseUpload(status: status, body: data)
    print("uploaded \(f.rel) (\(size(bodySize))) -> \(r.status) \(r.id)")
    uploaded.append(r.id)
}
if useAlbum, let album, !uploaded.isEmpty {
    try await client.addToAlbum(named: album, assetIds: uploaded)
    print("added \(uploaded.count) to \"\(album)\"")
}
