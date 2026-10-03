import Foundation

/// One photo or video on the card.
public struct CardFile: Identifiable, Hashable, Codable, Sendable {
    public enum Group: String, Codable, Sendable {
        /// Everything outside .Trashes: the shoot itself.
        case shoot
        /// Deleted on a Mac but never emptied. Real photos, kept apart so they
        /// don't land in the shoot's album, as the home pipeline does.
        case trash
    }

    /// Path relative to the card's root, "/"-separated.
    public let rel: String
    public let size: Int64
    public let modified: Date
    public let created: Date?
    public let group: Group

    public init(rel: String, size: Int64, modified: Date, created: Date?, group: Group) {
        self.rel = rel
        self.size = size
        self.modified = modified
        self.created = created
        self.group = group
    }

    public var id: String { rel }
    public var name: String { (rel as NSString).lastPathComponent }
    public var ext: String { (rel as NSString).pathExtension.lowercased() }

    /// Identifies these exact bytes well enough to reuse a hash: a camera never
    /// rewrites a file in place, so path, size and mtime together don't recur.
    public var cacheKey: String {
        "\(rel)|\(size)|\(Int64(modified.timeIntervalSince1970))"
    }

    /// The date Immich falls back to when a file has no EXIF date.
    public var takenDate: Date { created.map { min($0, modified) } ?? modified }

    public func url(in root: URL) -> URL {
        rel.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}
