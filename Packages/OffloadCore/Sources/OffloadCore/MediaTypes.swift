import Foundation

/// The file extensions Immich accepts, as it reports them from
/// /api/server/media-types. A hand-kept list drifts behind the server, so the
/// app asks each time and remembers the last answer; `fallback` is only for a
/// first launch with no connection.
public struct MediaTypes: Codable, Hashable, Sendable {
    public var image: Set<String>
    public var video: Set<String>

    public init(image: Set<String>, video: Set<String>) {
        self.image = Set(image.map(Self.normalise))
        self.video = Set(video.map(Self.normalise))
    }

    public func isMedia(_ ext: String) -> Bool {
        let e = Self.normalise(ext)
        return image.contains(e) || video.contains(e)
    }

    public func isVideo(_ ext: String) -> Bool { video.contains(Self.normalise(ext)) }

    /// RAW formats, to badge them in the grid.
    public static let raw: Set<String> = [
        "3fr", "ari", "arw", "cap", "cin", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff",
        "iiq", "k25", "kdc", "mrw", "nef", "nrw", "orf", "ori", "pef", "raf", "raw", "rw2",
        "rwl", "sr2", "srf", "srw", "x3f",
    ]

    /// What Immich 3.2 accepts, for when it can't be asked.
    public static let fallback = MediaTypes(
        image: [
            "3fr", "ari", "arw", "avif", "bmp", "cap", "cin", "cr2", "cr3", "crw", "dcr", "dng",
            "erf", "fff", "gif", "heic", "heif", "hif", "iiq", "insp", "jp2", "jpe", "jpeg",
            "jpg", "jxl", "k25", "kdc", "mpo", "mrw", "nef", "nrw", "orf", "ori", "pef", "png",
            "psd", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "svg", "tif", "tiff", "webp",
            "x3f",
        ],
        video: [
            "3gp", "3gpp", "avi", "flv", "insv", "m2t", "m2ts", "m4v", "mkv", "mov", "mp4", "mpe",
            "mpeg", "mpg", "mts", "mxf", "ts", "vob", "webm", "wmv",
        ])

    /// "JPG", ".jpg" and "jpg" are all "jpg".
    static func normalise(_ ext: String) -> String {
        var e = ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        return e
    }
}
