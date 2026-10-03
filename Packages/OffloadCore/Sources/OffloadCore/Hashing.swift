import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-1, which is what Immich keys every asset on. CryptoKit on the phone; a
/// plain implementation elsewhere so the package still builds on Linux.
public struct SHA1Hasher {
    #if canImport(CryptoKit)
    private var h = Insecure.SHA1()
    #else
    private var h = PlainSHA1()
    #endif

    public init() {}

    public mutating func update(_ data: Data) { h.update(data: data) }

    public mutating func finalizeHex() -> String {
        h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static let chunkSize = 4 << 20

    /// Reads the file in 4 MB chunks, so a 4 GB video never sits in memory.
    public static func hashFile(_ url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA1Hasher()
        var done: Int64 = 0
        while let chunk = try fh.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(chunk)
            done += Int64(chunk.count)
            progress?(done)
        }
        return hasher.finalizeHex()
    }
}

/// FIPS 180-4 SHA-1. Only used where CryptoKit isn't available.
struct PlainSHA1 {
    private var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
    private var pending = [UInt8]()
    private var length: UInt64 = 0

    mutating func update(data: Data) {
        length &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var i = 0
        while pending.count - i >= 64 {
            block(pending[i ..< i + 64])
            i += 64
        }
        pending.removeFirst(i)
    }

    mutating func finalize() -> [UInt8] {
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }
        for i in stride(from: 0, to: tail.count, by: 64) { block(tail[i ..< i + 64]) }
        return h.flatMap { v in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> UInt32($0)) } }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    private mutating func block(_ chunk: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 80)
        let b0 = chunk.startIndex
        for t in 0 ..< 16 {
            let i = b0 + 4 * t
            w[t] = UInt32(chunk[i]) << 24 | UInt32(chunk[i + 1]) << 16 | UInt32(chunk[i + 2]) << 8 | UInt32(chunk[i + 3])
        }
        for t in 16 ..< 80 { w[t] = Self.rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
        for t in 0 ..< 80 {
            let f: UInt32, k: UInt32
            switch t {
            case 0 ..< 20: f = (b & c) | (~b & d); k = 0x5A82_7999
            case 20 ..< 40: f = b ^ c ^ d; k = 0x6ED9_EBA1
            case 40 ..< 60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
            default: f = b ^ c ^ d; k = 0xCA62_C1D6
            }
            let temp = Self.rotl(a, 5) &+ f &+ e &+ k &+ w[t]
            e = d; d = c; c = Self.rotl(b, 30); b = a; a = temp
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
    }
}

/// Hashes already worked out, keyed by `CardFile.cacheKey`, so putting the same
/// card back in doesn't read every file again.
public final class HashCache: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var map: [String: String]
    private var dirty = false

    public init(url: URL) {
        self.url = url
        map = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    public subscript(key: String) -> String? {
        get { lock.lock(); defer { lock.unlock() }; return map[key] }
        set {
            lock.lock(); defer { lock.unlock() }
            if map[key] != newValue { map[key] = newValue; dirty = true }
        }
    }

    public func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let data = try? JSONEncoder().encode(map)
        dirty = false
        lock.unlock()
        try? data?.write(to: url, options: .atomic)
    }
}
