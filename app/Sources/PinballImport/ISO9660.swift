// Read-only ISO 9660 reader for the user's CD image. Handles cooked 2048-byte images (the
// 1995 CD is one, its primary volume descriptor has system id "CD-RTOS CD-BRIDGE", i.e. a
// CD-i Bridge / XA disc) and raw 2352-byte (Mode 1 or Mode 2 XA Form 1) or 2336-byte
// sector dumps such as .bin / GOG .gog images. Only the primary volume descriptor is used
// (8.3 upper-case names; XA system-use fields after the name are ignored).
import Foundation

public final class ISO9660Image: @unchecked Sendable {
    public struct Entry: Sendable {
        public var path: String          // "DIR/NAME.EXT" (no version suffix)
        public var isDirectory: Bool
        public var lba: Int
        public var size: Int
    }

    public let url: URL
    public private(set) var systemIdentifier = ""
    public private(set) var volumeIdentifier = ""
    /// "2048", "2352/mode1", "2352/mode2", "2336"
    public let sectorLayout: String
    public private(set) var entries: [Entry] = []

    private let handle: FileHandle
    private let fileSize: Int
    private let sectorSize: Int
    private let dataOffset: Int
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        let h = try FileHandle(forReadingFrom: url)
        let total = Int(((try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber)?.intValue ?? 0)
        // the sector layout: where the volume descriptor set (sector 16) starts with "CD001"
        func probe(_ size: Int, _ off: Int) -> Bool {
            let at = 16 * size + off
            guard at + 2048 <= total else { return false }
            try? h.seek(toOffset: UInt64(at))
            guard let d = try? h.read(upToCount: 6), d.count == 6 else { return false }
            return [UInt8](d)[1...5].elementsEqual(Array("CD001".utf8))
        }
        var layout: (Int, Int, String)? = nil
        for (s, o, name) in [(2048, 0, "2048"), (2352, 16, "2352/mode1"), (2352, 24, "2352/mode2"), (2336, 8, "2336")] where probe(s, o) {
            layout = (s, o, name); break
        }
        guard let layout else {
            try? h.close()
            throw ImportError("\(url.lastPathComponent): not an ISO 9660 image (no CD001 volume descriptor)")
        }
        handle = h
        fileSize = total
        sectorSize = layout.0; dataOffset = layout.1; sectorLayout = layout.2
        // volume descriptors: find the primary (type 1)
        var pvd: [UInt8]? = nil
        for i in 16..<64 {
            let s = try readSector(i)
            guard s[1...5].elementsEqual(Array("CD001".utf8)) else { break }
            if s[0] == 1 { pvd = s; break }
            if s[0] == 255 { break }
        }
        guard let pvd else { throw ImportError("\(url.lastPathComponent): no primary volume descriptor") }
        func text(_ r: Range<Int>) -> String {
            String(decoding: pvd[r], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        }
        systemIdentifier = text(8..<40)
        volumeIdentifier = text(40..<72)
        let blockSize = Int(pvd[128]) | Int(pvd[129]) << 8
        guard blockSize == 2048 else { throw ImportError("\(url.lastPathComponent): logical block size \(blockSize) is not supported") }
        let root = Array(pvd[156..<(156 + 34)])
        let rootLBA = ISO9660Image.le32(root, 2), rootSize = ISO9660Image.le32(root, 10)
        try walk(lba: rootLBA, size: rootSize, prefix: "", depth: 0)
    }

    deinit { try? handle.close() }

    static func le32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }

    private func readSector(_ lba: Int) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let at = lba * sectorSize + dataOffset
        guard at + 2048 <= fileSize else { throw ImportError("\(url.lastPathComponent): sector \(lba) is past the end of the image") }
        try handle.seek(toOffset: UInt64(at))
        guard let d = try handle.read(upToCount: 2048), d.count == 2048 else { throw ImportError("\(url.lastPathComponent): short read at sector \(lba)") }
        return [UInt8](d)
    }

    private func walk(lba: Int, size: Int, prefix: String, depth: Int) throws {
        guard depth < 16 else { return }
        let sectors = (size + 2047) / 2048
        for s in 0..<sectors {
            let sec = try readSector(lba + s)
            var p = 0
            while p < 2048 {
                let len = Int(sec[p])
                if len == 0 { break }                       // rest of the sector is padding
                guard p + len <= 2048, len >= 34 else { break }
                let rec = Array(sec[p..<(p + len)])
                p += len
                let nameLen = Int(rec[32])
                guard 33 + nameLen <= rec.count else { continue }
                let raw = Array(rec[33..<(33 + nameLen)])
                if nameLen == 1 && (raw[0] == 0 || raw[0] == 1) { continue }   // "." and ".."
                var name = String(decoding: raw, as: UTF8.self)
                if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
                if name.hasSuffix(".") { name.removeLast() }
                let flags = rec[25]
                let isDir = flags & 0x02 != 0
                if flags & 0x80 != 0 { throw ImportError("\(url.lastPathComponent): multi-extent file \(name) is not supported") }
                let e = Entry(path: prefix + name, isDirectory: isDir, lba: ISO9660Image.le32(rec, 2), size: ISO9660Image.le32(rec, 10))
                entries.append(e)
                if isDir { try walk(lba: e.lba, size: e.size, prefix: e.path + "/", depth: depth + 1) }
            }
        }
    }

    public func read(_ e: Entry) throws -> Data {
        guard !e.isDirectory else { throw ImportError("\(e.path) is a directory") }
        if sectorSize == 2048 {
            lock.lock(); defer { lock.unlock() }
            let at = e.lba * 2048
            guard at + e.size <= fileSize else { throw ImportError("\(url.lastPathComponent): \(e.path) runs past the end of the image") }
            try handle.seek(toOffset: UInt64(at))
            let d = try handle.read(upToCount: e.size) ?? Data()
            guard d.count == e.size else { throw ImportError("\(url.lastPathComponent): short read of \(e.path)") }
            return d
        }
        var out = Data(capacity: e.size)
        var left = e.size, lba = e.lba
        while left > 0 {
            let s = try readSector(lba)
            let n = min(left, 2048)
            out.append(contentsOf: s[0..<n])
            left -= n; lba += 1
        }
        return out
    }
}
