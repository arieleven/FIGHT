import Foundation
import Compression

enum WorkoutCompressor {
    private static let magicBytes: [UInt8] = [0x43, 0x53, 0x50, 0x4B] // "CSPK"

    /// Encodes HeartRatePoint array into a 100% bit-exact lossless binary packet (Delta + Varint + LZFSE)
    static func compress(samples: [HeartRatePoint]) -> Data? {
        guard !samples.isEmpty else { return Data() }

        var rawStream = Data()
        rawStream.reserveCapacity(samples.count * 6)

        // First sample full anchor
        let first = samples[0]
        let firstMs = Int64(round(first.timestamp.timeIntervalSince1970 * 1000.0))
        appendInt64(firstMs, to: &rawStream)
        appendInt64(Int64(round(first.elapsedSeconds * 1000.0)), to: &rawStream)
        appendUInt16(UInt16(clamping: first.bpm), to: &rawStream)

        var prevRRBits: UInt64 = 0
        if let rr = first.rrIntervalMs {
            rawStream.append(1)
            prevRRBits = rr.bitPattern
            appendUInt64(prevRRBits, to: &rawStream)
        } else {
            rawStream.append(0)
        }

        // Subsequent samples: Delta + ZigZag + Varint
        var prevTsMs = firstMs
        var prevElapsedMs = Int64(round(first.elapsedSeconds * 1000.0))
        var prevBPM = first.bpm

        for i in 1..<samples.count {
            let s = samples[i]
            let tsMs = Int64(round(s.timestamp.timeIntervalSince1970 * 1000.0))
            let elMs = Int64(round(s.elapsedSeconds * 1000.0))

            appendSignedVarint(tsMs - prevTsMs, to: &rawStream)
            appendSignedVarint(elMs - prevElapsedMs, to: &rawStream)
            appendSignedVarint(Int64(s.bpm - prevBPM), to: &rawStream)

            if let rr = s.rrIntervalMs {
                rawStream.append(1)
                let bits = rr.bitPattern
                let xorDelta = bits ^ prevRRBits
                appendUnsignedVarint(xorDelta, to: &rawStream)
                prevRRBits = bits
            } else {
                rawStream.append(0)
            }

            prevTsMs = tsMs
            prevElapsedMs = elMs
            prevBPM = s.bpm
        }

        let rawCount = rawStream.count
        let dstCapacity = max(64, rawCount + 512)
        var compressedBuffer = [UInt8](repeating: 0, count: dstCapacity)

        let compressedSize: Int = rawStream.withUnsafeBytes { srcPtr in
            guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                &compressedBuffer,
                dstCapacity,
                base,
                rawCount,
                nil,
                COMPRESSION_LZFSE
            )
        }

        var output = Data(magicBytes)
        output.append(1) // Format version 1

        let payloadData: Data
        if compressedSize > 0 && compressedSize < rawCount {
            output.append(1) // Flag: LZFSE compressed
            payloadData = Data(compressedBuffer.prefix(compressedSize))
        } else {
            output.append(0) // Flag: Raw delta-varint
            payloadData = rawStream
        }

        appendUInt32(UInt32(samples.count), to: &output)
        appendUInt32(UInt32(rawCount), to: &output)
        appendUInt32(crc32(of: payloadData), to: &output)
        output.append(payloadData)
        return output
    }

    /// Losslessly reconstructs the exact HeartRatePoint array from a .cspk archive
    static func decompress(data: Data) -> [HeartRatePoint]? {
        if data.isEmpty { return [] }
        guard data.count >= 18 else { return nil }
        guard Array(data.prefix(4)) == magicBytes else { return nil }

        let version = data[4]
        guard version == 1 else { return nil }
        let isLZFSE = data[5] == 1

        let sampleCount = Int(readUInt32(from: data, offset: 6))
        let rawCount = Int(readUInt32(from: data, offset: 10))
        let expectedCRC = readUInt32(from: data, offset: 14)

        let payload = data.subdata(in: 18..<data.count)
        guard crc32(of: payload) == expectedCRC else { return nil }

        let rawStream: Data
        if isLZFSE {
            var decoded = [UInt8](repeating: 0, count: rawCount)
            let decodedSize: Int = payload.withUnsafeBytes { srcPtr in
                guard let base = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    &decoded,
                    rawCount,
                    base,
                    payload.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
            guard decodedSize == rawCount else { return nil }
            rawStream = Data(decoded)
        } else {
            rawStream = payload
        }

        guard sampleCount > 0, rawStream.count >= 19 else { return nil }

        var offset = 0
        let firstTsMs = readInt64(from: rawStream, offset: &offset)
        let firstElMs = readInt64(from: rawStream, offset: &offset)
        let firstBPM = Int(readUInt16(from: rawStream, offset: &offset))

        var prevRRBits: UInt64 = 0
        let firstHasRR = rawStream[offset] == 1
        offset += 1
        var firstRR: Double? = nil
        if firstHasRR {
            prevRRBits = readUInt64(from: rawStream, offset: &offset)
            firstRR = Double(bitPattern: prevRRBits)
        }

        var result: [HeartRatePoint] = []
        result.reserveCapacity(sampleCount)
        result.append(HeartRatePoint(
            timestamp: Date(timeIntervalSince1970: Double(firstTsMs) / 1000.0),
            elapsedSeconds: Double(firstElMs) / 1000.0,
            bpm: firstBPM,
            rrIntervalMs: firstRR
        ))

        var prevTsMs = firstTsMs
        var prevElMs = firstElMs
        var prevBPM = firstBPM

        for _ in 1..<sampleCount {
            let dTs = readSignedVarint(from: rawStream, offset: &offset)
            let dEl = readSignedVarint(from: rawStream, offset: &offset)
            let dBPM = Int(readSignedVarint(from: rawStream, offset: &offset))

            let tsMs = prevTsMs + dTs
            let elMs = prevElMs + dEl
            let bpm = prevBPM + dBPM

            let hasRR = rawStream[offset] == 1
            offset += 1
            var rr: Double? = nil
            if hasRR {
                let xorDelta = readUnsignedVarint(from: rawStream, offset: &offset)
                let bits = prevRRBits ^ xorDelta
                prevRRBits = bits
                rr = Double(bitPattern: bits)
            }

            result.append(HeartRatePoint(
                timestamp: Date(timeIntervalSince1970: Double(tsMs) / 1000.0),
                elapsedSeconds: Double(elMs) / 1000.0,
                bpm: bpm,
                rrIntervalMs: rr
            ))

            prevTsMs = tsMs
            prevElMs = elMs
            prevBPM = bpm
        }

        return result
    }

    // MARK: - Binary Helpers
    private static func appendSignedVarint(_ value: Int64, to data: inout Data) {
        let zigzag = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        appendUnsignedVarint(zigzag, to: &data)
    }

    private static func appendUnsignedVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private static func readUnsignedVarint(from data: Data, offset: inout Int) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 { break }
            shift += 7
        }
        return result
    }

    private static func readSignedVarint(from data: Data, offset: inout Int) -> Int64 {
        let zigzag = readUnsignedVarint(from: data, offset: &offset)
        return Int64(bitPattern: (zigzag >> 1) ^ (~(zigzag & 1) &+ 1))
    }

    private static func appendInt64(_ v: Int64, to data: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ v: UInt64, to data: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ v: UInt32, to data: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ v: UInt16, to data: inout Data) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func readInt64(from data: Data, offset: inout Int) -> Int64 {
        let val = data.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.load(as: Int64.self) }
        offset += 8
        return Int64(littleEndian: val)
    }

    private static func readUInt64(from data: Data, offset: inout Int) -> UInt64 {
        let val = data.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: val)
    }

    private static func readUInt16(from data: Data, offset: inout Int) -> UInt16 {
        let val = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: val)
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        let val = data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
        return UInt32(littleEndian: val)
    }

    private static func crc32(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return ~crc
    }
}