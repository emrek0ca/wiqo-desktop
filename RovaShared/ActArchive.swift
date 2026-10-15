import Compression
import CryptoKit
import Foundation

/// Archives for Act, with no libraries: reading an npm package (gzip + tar) and writing a source ZIP.
public enum ActArchive {
    public enum ArchiveError: Error, Equatable { case notGzip, truncated, badChecksum, tooLarge }

    // MARK: Integrity

    /// The SRI string (`sha512-<base64>`) of some bytes.
    public static func sri512(_ data: Data) -> String {
        "sha512-" + Data(SHA512.hash(data: data)).base64EncodedString()
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `data` matches an SRI value (`sha512-...`; several values separated by spaces: any one may match).
    public static func matches(_ data: Data, integrity: String) -> Bool {
        integrity.split(separator: " ").contains { token in
            token.hasPrefix("sha512-") && String(token) == sri512(data)
        }
    }

    // MARK: gzip

    /// The contents of a gzip file. The header is skipped, the deflate stream inflated and the trailer (CRC-32, size) checked.
    public static func gunzip(_ data: Data, maxBytes: Int = 64 * 1024 * 1024) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw ArchiveError.notGzip }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw ArchiveError.truncated }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { throw ArchiveError.truncated }
        let payload = Data(bytes[index..<(bytes.count - 8)])
        let trailer = bytes[(bytes.count - 8)...]
        let expectedCRC = trailer.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let expectedSize = trailer.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let inflated: Data
        do { inflated = try (payload as NSData).decompressed(using: .zlib) as Data } catch { throw ArchiveError.truncated }
        guard inflated.count <= maxBytes else { throw ArchiveError.tooLarge }
        guard UInt32(truncatingIfNeeded: inflated.count) == expectedSize, crc32(inflated) == expectedCRC else { throw ArchiveError.badChecksum }
        return inflated
    }

    // MARK: tar

    /// One file out of a tar stream (ustar, pax and GNU long names), by its full name.
    public static func tarEntry(_ tar: Data, named wanted: String) -> Data? {
        let bytes = [UInt8](tar)
        var offset = 0
        var longName: String?
        var paxPath: String?
        while offset + 512 <= bytes.count {
            let header = bytes[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) { return nil }
            func field(_ from: Int, _ length: Int) -> [UInt8] { Array(header.dropFirst(from).prefix(length)) }
            func text(_ raw: [UInt8]) -> String { String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            let size = Int(text(field(124, 12)).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = bytes[offset + 156]
            let dataStart = offset + 512
            guard size >= 0, dataStart + size <= bytes.count else { return nil }
            let body = Data(bytes[dataStart..<(dataStart + size)])
            offset = dataStart + ((size + 511) / 512) * 512
            switch type {
            case UInt8(ascii: "L"):
                longName = text([UInt8](body))
                continue
            case UInt8(ascii: "x"):
                paxPath = paxValue("path", in: body)
                continue
            case UInt8(ascii: "g"):
                continue
            default:
                break
            }
            var name = text(field(0, 100))
            let prefix = text(field(345, 155))
            if !prefix.isEmpty { name = prefix + "/" + name }
            if let long = longName { name = long }
            if let pax = paxPath { name = pax }
            longName = nil
            paxPath = nil
            guard type == 0 || type == UInt8(ascii: "0") else { continue }
            if name == wanted || name.hasPrefix("./") && String(name.dropFirst(2)) == wanted { return body }
        }
        return nil
    }

    private static func paxValue(_ key: String, in body: Data) -> String? {
        let text = String(decoding: body, as: UTF8.self)
        for record in text.split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let pair = record[record.index(after: space)...]
            if pair.hasPrefix(key + "=") { return String(pair.dropFirst(key.count + 1)) }
        }
        return nil
    }

    // MARK: ZIP (stored, no compression)

    /// A project's path as it may appear in an archive: forward slashes, no leading slash, no `.` or `..`, no hidden
    /// first-level files. Nil when the path cannot be made safe.
    public static func normalizedPath(_ path: String) -> String? {
        guard !path.contains("\\"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let joined = parts.joined(separator: "/")
        return joined.utf8.count <= 240 ? joined : nil
    }

    public static func zip(_ files: [(path: String, data: Data)], date: Date = Date()) -> Data {
        var archive = Data()
        var central = Data()
        var count: UInt16 = 0
        let (dosDate, dosTime) = dosStamp(date)
        func put16(_ value: UInt16, _ data: inout Data) { data.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)]) }
        func put32(_ value: UInt32, _ data: inout Data) { data.append(contentsOf: (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xff) }) }
        var seen = Set<String>()
        for file in files {
            guard let name = normalizedPath(file.path), seen.insert(name).inserted else { continue }
            let nameBytes = Data(name.utf8)
            let crc = crc32(file.data)
            let size = UInt32(file.data.count)
            let offset = UInt32(archive.count)
            put32(0x04034b50, &archive); put16(20, &archive); put16(0x0800, &archive); put16(0, &archive)
            put16(dosTime, &archive); put16(dosDate, &archive); put32(crc, &archive); put32(size, &archive); put32(size, &archive)
            put16(UInt16(nameBytes.count), &archive); put16(0, &archive)
            archive.append(nameBytes); archive.append(file.data)
            put32(0x02014b50, &central); put16(20, &central); put16(20, &central); put16(0x0800, &central); put16(0, &central)
            put16(dosTime, &central); put16(dosDate, &central); put32(crc, &central); put32(size, &central); put32(size, &central)
            put16(UInt16(nameBytes.count), &central); put16(0, &central); put16(0, &central); put16(0, &central); put16(0, &central)
            put32(0, &central); put32(offset, &central)
            central.append(nameBytes)
            count += 1
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        put32(0x06054b50, &archive); put16(0, &archive); put16(0, &archive); put16(count, &archive); put16(count, &archive)
        put32(UInt32(central.count), &archive); put32(centralOffset, &archive); put16(0, &archive)
        return archive
    }

    private static func dosStamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year = max(1980, c.year ?? 1980) - 1980
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let hourBits = (c.hour ?? 0) << 11
        let minuteBits = (c.minute ?? 0) << 5
        let twoSecondBits = (c.second ?? 0) / 2
        let time = UInt16(hourBits | minuteBits | twoSecondBits)
        return (day, time)
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
