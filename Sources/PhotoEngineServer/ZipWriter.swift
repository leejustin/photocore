import Foundation

/// Writes a zip of files stored as they are (photos don't compress), streamed
/// from disk so a large book never sits in memory. Zip64 is not needed: a book
/// is capped well under 4 GB.
struct ZipWriter {
    struct Entry {
        var name: String
        var source: URL
    }

    enum ZipError: Error {
        case tooLarge
        case cannotWrite
    }

    static func write(_ entries: [Entry], to url: URL, modified: Date = Date()) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else { throw ZipError.cannotWrite }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        let (time, date) = dosTime(modified)
        var central = Data()
        var offset: UInt32 = 0
        for entry in entries {
            let size = try fm.attributesOfItem(atPath: entry.source.path)[.size] as? UInt64 ?? 0
            guard size < UInt64(UInt32.max), UInt64(offset) + size < UInt64(UInt32.max) - 1_000_000 else { throw ZipError.tooLarge }
            let crc = try crc32(of: entry.source)
            let name = Data(entry.name.utf8)
            var local = Data()
            local.append(le32(0x04034b50))
            local.append(le16(20))          // version needed
            local.append(le16(0x0800))      // UTF-8 names
            local.append(le16(0))           // stored
            local.append(le16(time)); local.append(le16(date))
            local.append(le32(crc)); local.append(le32(UInt32(size))); local.append(le32(UInt32(size)))
            local.append(le16(UInt16(name.count))); local.append(le16(0))
            local.append(name)
            try out.write(contentsOf: local)
            let input = try FileHandle(forReadingFrom: entry.source)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            try input.close()

            central.append(le32(0x02014b50))
            central.append(le16(20)); central.append(le16(20)); central.append(le16(0x0800)); central.append(le16(0))
            central.append(le16(time)); central.append(le16(date))
            central.append(le32(crc)); central.append(le32(UInt32(size))); central.append(le32(UInt32(size)))
            central.append(le16(UInt16(name.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0))
            central.append(le32(offset))
            central.append(name)
            offset += UInt32(local.count) + UInt32(size)
        }
        var end = Data()
        end.append(le32(0x06054b50)); end.append(le16(0)); end.append(le16(0))
        end.append(le16(UInt16(entries.count))); end.append(le16(UInt16(entries.count)))
        end.append(le32(UInt32(central.count))); end.append(le32(offset)); end.append(le16(0))
        try out.write(contentsOf: central)
        try out.write(contentsOf: end)
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func dosTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(max(0, (parts.year ?? 1980) - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }

    static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(of url: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc: UInt32 = 0xFFFFFFFF
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            for byte in chunk { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }
}
