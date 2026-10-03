import Foundation

/// Lists the photos and videos on a card, with the same rules as the home
/// sdcard-import pipeline so both agree on what's on it.
public enum CardScanner {
    /// Index databases and the like that a Mac or Windows leaves on a card.
    /// Never photos, and skipped wherever they turn up.
    public static let junkDirectories: Set<String> = [
        ".Spotlight-V100", ".fseventsd", "System Volume Information",
        ".TemporaryItems", ".DocumentRevisions-V100", ".fseventsd-uuid",
    ]
    public static let trashDirectory = ".Trashes"

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey,
    ]

    /// Every importable file under `root`, sorted by path.
    public static func scan(_ root: URL, types: MediaTypes) throws -> [CardFile] {
        var out: [CardFile] = []
        try walk(root, rel: "", group: .shoot, top: true, types: types, into: &out)
        return out.sorted { $0.rel < $1.rel }
    }

    private static func walk(_ dir: URL, rel: String, group: CardFile.Group, top: Bool,
                             types: MediaTypes, into out: inout [CardFile]) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [])
        for url in entries {
            let name = url.lastPathComponent
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if junkDirectories.contains(name) { continue }
                let g: CardFile.Group = top && name == trashDirectory ? .trash : group
                // One unreadable folder shouldn't hide the rest of the card.
                try? walk(url, rel: rel + name + "/", group: g, top: false, types: types, into: &out)
                continue
            }
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            guard types.isMedia((name as NSString).pathExtension) else { continue }
            out.append(CardFile(
                rel: rel + name,
                size: Int64(v.fileSize ?? 0),
                modified: v.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                created: v.creationDate,
                group: group))
        }
    }
}

/// The album a card's shoot goes into, named the way the home pipeline names it
/// ("SD import 2026-09-28", or "SD import 2026-09-28 to 2026-10-02"), so a card
/// started on the phone and finished at home ends up in one album.
public enum AlbumName {
    public static let prefix = "SD import"

    /// Named from the whole shoot on the card, not just the files being uploaded:
    /// the pipeline sees the whole card, and the two have to agree.
    public static func forCard(_ files: [CardFile], calendar: Calendar = .current) -> String? {
        let dates = files.filter { $0.group == .shoot }.map(\.modified)
        guard let lo = dates.min(), let hi = dates.max() else { return nil }
        let a = day(lo, calendar), b = day(hi, calendar)
        return a == b ? "\(prefix) \(a)" : "\(prefix) \(a) to \(b)"
    }

    public static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
