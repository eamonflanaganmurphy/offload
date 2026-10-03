import Foundation

/// The multipart/form-data body for POST /api/assets, written to a file.
///
/// A background URLSession can only upload from a file, and it carries on with
/// the phone locked or the app closed. So each photo is copied off the card into
/// a body file once, hashed on the way, and the system uploads that.
public struct MultipartBody {
    public let boundary: String

    public init(boundary: String = "offload-" + UUID().uuidString) {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// The form fields Immich 3 wants alongside the file.
    public static func fields(for file: CardFile) -> [(String, String)] {
        [
            ("fileCreatedAt", iso8601(file.takenDate)),
            ("fileModifiedAt", iso8601(file.modified)),
            ("filename", file.name),
        ]
    }

    public func head(fields: [(String, String)], fileField: String, filename: String) -> Data {
        var s = ""
        for (name, value) in fields {
            s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        s += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(Self.quoted(filename))\"\r\n"
        s += "Content-Type: application/octet-stream\r\n\r\n"
        return Data(s.utf8)
    }

    public var tail: Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    /// Writes the whole body for `file` to `dest`, reading the original once and
    /// hashing it on the way. `progress` gets the bytes read from the card so far.
    public func write(_ file: CardFile, from source: URL, to dest: URL,
                      attributes: [FileAttributeKey: Any]? = nil,
                      isCancelled: () -> Bool = { false },
                      progress: ((Int64) -> Void)? = nil) throws -> (sha1: String, bodySize: Int64) {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
        }
        let out = try FileHandle(forWritingTo: dest)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? out.close(); try? input.close() }

        var hasher = SHA1Hasher()
        let headData = head(fields: Self.fields(for: file), fileField: "assetData", filename: file.name)
        try out.write(contentsOf: headData)
        var read: Int64 = 0
        while let chunk = try input.read(upToCount: SHA1Hasher.chunkSize), !chunk.isEmpty {
            if isCancelled() { throw CancellationError() }
            hasher.update(chunk)
            try out.write(contentsOf: chunk)
            read += Int64(chunk.count)
            progress?(read)
        }
        try out.write(contentsOf: tail)
        return (hasher.finalizeHex(), Int64(headData.count) + read + Int64(tail.count))
    }

    static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
