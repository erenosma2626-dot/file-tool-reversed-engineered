import Foundation
import Compression

// MARK: - Public types

enum ZipError: Error { case invalidArchive, entryNotFound(String), unsupportedCompression(Int), corrupted }

struct ZipEntry { let path: String; let isDirectory: Bool; let uncompressedSize: Int }

// MARK: - Low-level helpers

/// Reads a little-endian UInt16 at `offset` (relative to the start of `data`).
/// Byte-by-byte assembly, so no unaligned loads. Throws on out-of-bounds.
private func zipReadUInt16(_ data: Data, _ offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else { throw ZipError.invalidArchive }
    let base = data.startIndex + offset
    let b0 = UInt16(data[base])
    let b1 = UInt16(data[base + 1])
    return b0 | (b1 << 8)
}

/// Reads a little-endian UInt32 at `offset` (relative to the start of `data`).
private func zipReadUInt32(_ data: Data, _ offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { throw ZipError.invalidArchive }
    let base = data.startIndex + offset
    let b0 = UInt32(data[base])
    let b1 = UInt32(data[base + 1])
    let b2 = UInt32(data[base + 2])
    let b3 = UInt32(data[base + 3])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

private func appendUInt16(_ data: inout Data, _ value: UInt16) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32(_ data: inout Data, _ value: UInt32) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}

/// Standard CRC-32 (polynomial 0xEDB88320), table driven.
fileprivate enum ZipCRC32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            t[i] = c
        }
        return t
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = ZipCRC32.table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Reader

final class ZipReader {
    let entries: [ZipEntry]

    private struct Record {
        let entry: ZipEntry
        let method: Int
        let crc: UInt32
        let compressedSize: Int
        let localHeaderOffset: Int
    }

    private let archive: Data
    private let records: [Record]
    private let lookup: [String: Int]

    /// Reads the whole file into memory and parses its central directory.
    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parsed = try ZipReader.parseCentralDirectory(data)
        archive = data
        records = parsed
        entries = parsed.map { $0.entry }
        lookup = ZipReader.makeLookup(parsed)
    }

    init(data: Data) throws {
        let parsed = try ZipReader.parseCentralDirectory(data)
        archive = data
        records = parsed
        entries = parsed.map { $0.entry }
        lookup = ZipReader.makeLookup(parsed)
    }

    func contains(_ path: String) -> Bool {
        return lookup[path] != nil
    }

    /// Returns the decompressed bytes of the entry with exactly this path.
    func data(for path: String) throws -> Data {
        guard let index = lookup[path] else { throw ZipError.entryNotFound(path) }
        let record = records[index]
        let headerOffset = record.localHeaderOffset

        // Local file header: its name/extra lengths may differ from the central directory.
        let signature = try zipReadUInt32(archive, headerOffset)
        guard signature == 0x04034b50 else { throw ZipError.invalidArchive }
        let nameLengthRaw = try zipReadUInt16(archive, headerOffset + 26)
        let extraLengthRaw = try zipReadUInt16(archive, headerOffset + 28)
        let nameLength = Int(nameLengthRaw)
        let extraLength = Int(extraLengthRaw)

        let payloadStart = headerOffset + 30 + nameLength + extraLength
        let payloadEnd = payloadStart + record.compressedSize
        guard payloadStart >= 0, payloadEnd <= archive.count else { throw ZipError.invalidArchive }
        let compressed = archive.subdata(
            in: (archive.startIndex + payloadStart)..<(archive.startIndex + payloadEnd)
        )

        let output: Data
        switch record.method {
        case 0:
            output = compressed
        case 8:
            output = try ZipReader.inflate(compressed, expectedSize: record.entry.uncompressedSize)
        default:
            throw ZipError.unsupportedCompression(record.method)
        }

        guard output.count == record.entry.uncompressedSize else { throw ZipError.corrupted }
        guard ZipCRC32.checksum(output) == record.crc else { throw ZipError.corrupted }
        return output
    }

    // MARK: Parsing

    private static func makeLookup(_ records: [Record]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, record) in records.enumerated() where map[record.entry.path] == nil {
            map[record.entry.path] = index
        }
        return map
    }

    private static func decodeName(_ bytes: Data) -> String {
        // Try UTF-8 first (bit 11 says it is UTF-8; otherwise legacy encodings are tolerated).
        if let s = String(data: bytes, encoding: .utf8) {
            return s
        }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [Record] {
        let size = data.count
        guard size >= 22 else { throw ZipError.invalidArchive }

        // Find the End Of Central Directory record by scanning backwards.
        // It is at least 22 bytes from the end; the comment can add up to 65535 bytes.
        let lowest = max(0, size - 22 - 65535)
        var eocd = -1
        var pos = size - 22
        while pos >= lowest {
            let sig = try zipReadUInt32(data, pos)
            if sig == 0x06054b50 {
                eocd = pos
                break
            }
            pos -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalidArchive }

        let entryCountRaw = try zipReadUInt16(data, eocd + 10)
        let cdSize = try zipReadUInt32(data, eocd + 12)
        let cdOffset = try zipReadUInt32(data, eocd + 16)
        if entryCountRaw == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            // ZIP64 is not supported.
            throw ZipError.invalidArchive
        }
        let entryCount = Int(entryCountRaw)
        let cdStart = Int(cdOffset)
        let cdEnd = cdStart + Int(cdSize)
        guard cdStart >= 0, cdEnd <= size else { throw ZipError.invalidArchive }

        var records: [Record] = []
        records.reserveCapacity(entryCount)
        var p = cdStart
        for _ in 0..<entryCount {
            let sig = try zipReadUInt32(data, p)
            guard sig == 0x02014b50 else { throw ZipError.invalidArchive }

            let method = Int(try zipReadUInt16(data, p + 10))
            let crc = try zipReadUInt32(data, p + 16)
            let compressedSize = try zipReadUInt32(data, p + 20)
            let uncompressedSize = try zipReadUInt32(data, p + 24)
            let nameLength = Int(try zipReadUInt16(data, p + 28))
            let extraLength = Int(try zipReadUInt16(data, p + 30))
            let commentLength = Int(try zipReadUInt16(data, p + 32))
            let localOffset = try zipReadUInt32(data, p + 42)

            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                throw ZipError.invalidArchive
            }

            let nameStart = p + 46
            guard nameStart + nameLength <= size else { throw ZipError.invalidArchive }
            let nameBytes = data.subdata(
                in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLength)
            )
            let name = decodeName(nameBytes)

            let entry = ZipEntry(
                path: name,
                isDirectory: name.hasSuffix("/"),
                uncompressedSize: Int(uncompressedSize)
            )
            records.append(Record(
                entry: entry,
                method: method,
                crc: crc,
                compressedSize: Int(compressedSize),
                localHeaderOffset: Int(localOffset)
            ))

            p = nameStart + nameLength + extraLength + commentLength
        }
        return records
    }

    // MARK: Decompression

    /// Raw deflate decode (COMPRESSION_ZLIB in Apple's Compression framework is raw deflate).
    private static func inflate(_ source: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard !source.isEmpty else { throw ZipError.corrupted }

        let capacity = max(expectedSize, 1)
        var output = [UInt8](repeating: 0, count: capacity)
        let decoded: Int = source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let srcBase = raw.baseAddress else { return 0 }
            let src = srcBase.assumingMemoryBound(to: UInt8.self)
            return output.withUnsafeMutableBufferPointer { (dst: inout UnsafeMutableBufferPointer<UInt8>) -> Int in
                guard let dstBase = dst.baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, capacity, src, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded == expectedSize else { throw ZipError.corrupted }
        return Data(output)
    }
}

// MARK: - Writer

final class ZipWriter {
    private struct Item {
        let name: Data
        let method: UInt16
        let crc: UInt32
        let payload: Data
        let uncompressedSize: Int
        let isDirectory: Bool
    }

    // Fixed timestamp: 1 Jan 2020 00:00.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = UInt16(((2020 - 1980) << 9) | (1 << 5) | 1)

    private var items: [Item] = []

    init() {}

    /// Adds an entry. Compressed with deflate only when it actually gets smaller.
    func add(path: String, data: Data, compress: Bool = true) {
        let crc = ZipCRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if compress, !data.isEmpty, let packed = ZipWriter.deflate(data), packed.count < data.count {
            method = 8
            payload = packed
        }
        items.append(Item(
            name: Data(path.utf8),
            method: method,
            crc: crc,
            payload: payload,
            uncompressedSize: data.count,
            isDirectory: path.hasSuffix("/")
        ))
    }

    func add(path: String, string: String, compress: Bool = true) {
        add(path: path, data: Data(string.utf8), compress: compress)
    }

    /// Builds the complete archive in memory.
    func finalize() -> Data {
        var out = Data()
        var localOffsets: [UInt32] = []
        localOffsets.reserveCapacity(items.count)

        // Local file headers and file data.
        for item in items {
            localOffsets.append(UInt32(truncatingIfNeeded: out.count))
            appendUInt32(&out, 0x04034b50)                       // local file header signature
            appendUInt16(&out, 20)                               // version needed to extract
            appendUInt16(&out, 0x0800)                           // flags: UTF-8 names
            appendUInt16(&out, item.method)                      // compression method
            appendUInt16(&out, ZipWriter.dosTime)
            appendUInt16(&out, ZipWriter.dosDate)
            appendUInt32(&out, item.crc)
            appendUInt32(&out, UInt32(truncatingIfNeeded: item.payload.count))
            appendUInt32(&out, UInt32(truncatingIfNeeded: item.uncompressedSize))
            appendUInt16(&out, UInt16(truncatingIfNeeded: item.name.count))
            appendUInt16(&out, 0)                                // extra field length
            out.append(item.name)
            out.append(item.payload)
        }

        // Central directory.
        let centralStart = out.count
        for (index, item) in items.enumerated() {
            let externalAttributes: UInt32 = item.isDirectory
                ? (UInt32(0o040755) << 16)
                : (UInt32(0o100644) << 16)
            appendUInt32(&out, 0x02014b50)                       // central directory signature
            appendUInt16(&out, 0x031E)                           // version made by (3 << 8 | 30)
            appendUInt16(&out, 20)                               // version needed
            appendUInt16(&out, 0x0800)                           // flags
            appendUInt16(&out, item.method)
            appendUInt16(&out, ZipWriter.dosTime)
            appendUInt16(&out, ZipWriter.dosDate)
            appendUInt32(&out, item.crc)
            appendUInt32(&out, UInt32(truncatingIfNeeded: item.payload.count))
            appendUInt32(&out, UInt32(truncatingIfNeeded: item.uncompressedSize))
            appendUInt16(&out, UInt16(truncatingIfNeeded: item.name.count))
            appendUInt16(&out, 0)                                // extra field length
            appendUInt16(&out, 0)                                // comment length
            appendUInt16(&out, 0)                                // disk number start
            appendUInt16(&out, 0)                                // internal attributes
            appendUInt32(&out, externalAttributes)
            appendUInt32(&out, localOffsets[index])
            out.append(item.name)
        }
        let centralSize = out.count - centralStart

        // End of central directory.
        appendUInt32(&out, 0x06054b50)
        appendUInt16(&out, 0)                                    // this disk
        appendUInt16(&out, 0)                                    // disk with central directory
        appendUInt16(&out, UInt16(truncatingIfNeeded: items.count))
        appendUInt16(&out, UInt16(truncatingIfNeeded: items.count))
        appendUInt32(&out, UInt32(truncatingIfNeeded: centralSize))
        appendUInt32(&out, UInt32(truncatingIfNeeded: centralStart))
        appendUInt16(&out, 0)                                    // comment length
        return out
    }

    /// Finalizes and writes atomically to `url`.
    func write(to url: URL) throws {
        let data = finalize()
        try data.write(to: url, options: .atomic)
    }

    /// Raw deflate encode. Returns nil if the encoder failed.
    private static func deflate(_ source: Data) -> Data? {
        guard !source.isEmpty else { return nil }
        let capacity = source.count + 1024 + source.count / 10
        var output = [UInt8](repeating: 0, count: capacity)
        let written: Int = source.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let srcBase = raw.baseAddress else { return 0 }
            let src = srcBase.assumingMemoryBound(to: UInt8.self)
            return output.withUnsafeMutableBufferPointer { (dst: inout UnsafeMutableBufferPointer<UInt8>) -> Int in
                guard let dstBase = dst.baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, capacity, src, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(output[0..<written])
    }
}
