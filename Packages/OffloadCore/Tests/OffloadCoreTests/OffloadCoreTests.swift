import Foundation
import XCTest
@testable import OffloadCore

final class HashingTests: XCTestCase {
    func hex(_ s: String) -> String {
        var h = SHA1Hasher()
        h.update(Data(s.utf8))
        return h.finalizeHex()
    }

    func testKnownVectors() {
        XCTAssertEqual(hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    func testChunkedEqualsWhole() {
        let data = Data((0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        var whole = SHA1Hasher()
        whole.update(data)
        var parts = SHA1Hasher()
        for start in stride(from: 0, to: data.count, by: 777) {
            parts.update(data[start ..< min(start + 777, data.count)])
        }
        XCTAssertEqual(whole.finalizeHex(), parts.finalizeHex())
    }

    func testHashCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = HashCache(url: url)
        a["DCIM/1.JPG|10|5"] = "abc"
        a.save()
        XCTAssertEqual(HashCache(url: url)["DCIM/1.JPG|10|5"], "abc")
    }
}

final class ScannerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("card-" + UUID().uuidString)
        try make("DCIM/100MSDCF/DSC00001.JPG", day: 1)
        try make("DCIM/100MSDCF/DSC00001.ARW", day: 1)
        try make("DCIM/100MSDCF/._DSC00001.JPG", day: 1)
        try make("PRIVATE/M4ROOT/CLIP/C0001.MP4", day: 3)
        try make("DCIM/100MSDCF/notes.txt", day: 1)
        try make(".Spotlight-V100/Store-V2/x.jpg", day: 1)
        try make(".DS_Store", day: 1)
        try make(".Trashes/501/DSC00009.JPG", day: 9)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func make(_ rel: String, day: Int) throws {
        let url = rel.split(separator: "/").reduce(root!) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(rel.utf8).write(to: url)
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                  year: 2026, month: 9, day: day, hour: 12).date!
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testFindsMediaAndSkipsJunk() throws {
        let files = try CardScanner.scan(root, types: .fallback)
        XCTAssertEqual(files.map(\.rel), [
            ".Trashes/501/DSC00009.JPG",
            "DCIM/100MSDCF/DSC00001.ARW",
            "DCIM/100MSDCF/DSC00001.JPG",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
        ])
        XCTAssertEqual(files.first?.group, .trash)
        XCTAssertEqual(files.filter { $0.group == .shoot }.count, 3)
        XCTAssertEqual(files.last?.url(in: root).lastPathComponent, "C0001.MP4")
    }

    func testAlbumNameLeavesOutTheTrash() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let files = try CardScanner.scan(root, types: .fallback)
        XCTAssertEqual(AlbumName.forCard(files, calendar: utc), "SD import 2026-09-01 to 2026-09-03")
        XCTAssertEqual(AlbumName.forCard(files.filter { $0.ext == "jpg" }, calendar: utc), "SD import 2026-09-01")
        XCTAssertNil(AlbumName.forCard([], calendar: utc))
    }

    func testMediaTypes() {
        let t = MediaTypes(image: [".JPG", ".arw"], video: [".mp4"])
        XCTAssertTrue(t.isMedia("jpg"))
        XCTAssertTrue(t.isMedia(".ARW"))
        XCTAssertTrue(t.isVideo("MP4"))
        XCTAssertFalse(t.isMedia("xmp"))
    }
}

final class MultipartTests: XCTestCase {
    func testBodyWrapsTheFileAndHashesOnlyTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data((0 ..< 9_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let src = dir.appendingPathComponent("A \"B\".JPG")
        try payload.write(to: src)
        let file = CardFile(rel: "DCIM/A \"B\".JPG", size: Int64(payload.count),
                            modified: Date(timeIntervalSince1970: 1_790_000_000), created: nil, group: .shoot)

        let body = MultipartBody(boundary: "XYZ")
        let dest = dir.appendingPathComponent("body")
        let (sha, size) = try body.write(file, from: src, to: dest)

        XCTAssertEqual(sha, try SHA1Hasher.hashFile(src))
        let written = try Data(contentsOf: dest)
        XCTAssertEqual(Int64(written.count), size)
        let text = String(decoding: written.prefix(600), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--XYZ\r\nContent-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n2026-09-21T"))
        XCTAssertTrue(text.contains("name=\"filename\"\r\n\r\nA \"B\".JPG\r\n"))
        XCTAssertTrue(text.contains("name=\"assetData\"; filename=\"A \\\"B\\\".JPG\""))
        XCTAssertTrue(written.suffix(9).elementsEqual(Data("\r\n--XYZ--\r\n".utf8).suffix(9)))
        let start = written.range(of: Data("\r\n\r\n".utf8), in: written.range(of: Data("assetData".utf8))!.upperBound ..< written.count)!.upperBound
        XCTAssertEqual(written[start ..< start + payload.count], payload)
    }
}

final class ClientTests: XCTestCase {
    func testServerAddresses() {
        XCTAssertEqual(ImmichClient.apiURL("photos.example.com")?.absoluteString, "https://photos.example.com/api")
        XCTAssertEqual(ImmichClient.apiURL("https://photos.example.com/")?.absoluteString, "https://photos.example.com/api")
        XCTAssertEqual(ImmichClient.apiURL("https://photos.example.com/api")?.absoluteString, "https://photos.example.com/api")
        XCTAssertEqual(ImmichClient.apiURL("192.168.0.68:2283")?.absoluteString, "http://192.168.0.68:2283/api")
        XCTAssertEqual(ImmichClient.apiURL("nas.local:2283")?.absoluteString, "http://nas.local:2283/api")
        XCTAssertNil(ImmichClient.apiURL(""))
        XCTAssertNil(ImmichClient.apiURL("not a server"))
    }

    func testParsesUploadAnswers() throws {
        let ok = try ImmichClient.parseUpload(status: 201, body: Data(#"{"id":"a","status":"created"}"#.utf8))
        XCTAssertEqual(ok.status, "created")
        let dup = try ImmichClient.parseUpload(status: 200, body: Data(#"{"id":"b","status":"duplicate"}"#.utf8))
        XCTAssertEqual(dup.id, "b")
        XCTAssertThrowsError(try ImmichClient.parseUpload(status: 403, body: Data(#"{"message":"Missing required permission: asset.upload"}"#.utf8))) {
            XCTAssertEqual(($0 as? ImmichError)?.message, "Missing required permission: asset.upload")
        }
    }
}
