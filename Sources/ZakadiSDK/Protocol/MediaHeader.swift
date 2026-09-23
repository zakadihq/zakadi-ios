import Foundation

/// Why a binary media message breaks the framing of spec 01 1.3. The raw value is the
/// stable code the conformance vectors name (`vectors/framing/*.json`, spec 01 1.12).
enum FramingError: String, Error {
    case shortHeader = "short_header"
    case unsupportedVersion = "unsupported_version"
    case reservedBitSet = "reserved_bit_set"
    case reservedBitsSet = "reserved_bits_set"
    case shortProbe = "short_probe"
    case truncatedBatchRecord = "truncated_batch_record"
    case batchOutOfOrder = "batch_out_of_order"
    case emptyBatch = "empty_batch"
    /// Encoding only: a rung above 15 does not fit the header's four bits.
    case badRung = "bad_rung"
}

/// The `type` field, bits 5-4 of header byte 0. Its two bits hold exactly these four
/// values, declared in raw-value order.
enum MediaType: UInt8, CaseIterable {
    case video = 0
    case audio = 1
    case probe = 2
    case audioBatch = 3
}

/// The 8-byte header of every binary media message (spec 01 1.3.1): multi-byte fields
/// are little-endian and bit 7 is the most significant bit of a byte.
struct MediaHeader: Equatable {
    /// Header length in bytes; the payload follows it.
    static let length = 8
    /// The framing version this codec reads and writes, bits 7-6 of byte 0.
    static let version: UInt8 = 0

    var type: MediaType
    /// Video: the access unit is an IDR (or a VP8 keyframe).
    var keyframe = false
    /// Video: SPS and PPS (or the codec configuration) precede the slice data.
    var paramSets = false
    /// The first message after a rung change, which a `rung` JSON message accompanies.
    var rungChanged = false
    /// The ladder rung the message was encoded at, 0...15.
    var rung: UInt8 = 0
    /// Per type, starting at 0; see `seq(after:)`.
    var seq: UInt16
    /// Capture timestamp in milliseconds on the session media clock.
    var ptsMs: UInt32

    /// The `seq` that follows `seq` in its type's sequence: uint16, so 65535 is followed
    /// by 0.
    static func seq(after seq: UInt16) -> UInt16 {
        seq &+ 1
    }
}

extension MediaHeader {
    /// Reads the header at the start of `message`; the payload after it is not examined.
    init(decoding message: Data) throws(FramingError) {
        guard message.count >= Self.length else { throw .shortHeader }
        let bytes = [UInt8](message.prefix(Self.length))
        guard bytes[0] >> 6 == Self.version else { throw .unsupportedVersion }
        guard bytes[0] & 0x01 == 0 else { throw .reservedBitSet }
        guard bytes[1] & 0x0F == 0 else { throw .reservedBitsSet }
        self.init(
            type: MediaType.allCases[Int((bytes[0] >> 4) & 0x03)],
            keyframe: (bytes[0] & 0x08) != 0,
            paramSets: (bytes[0] & 0x04) != 0,
            rungChanged: (bytes[0] & 0x02) != 0,
            rung: bytes[1] >> 4,
            seq: UInt16(littleEndianBytes: bytes[2..<4]),
            ptsMs: UInt32(littleEndianBytes: bytes[4..<8])
        )
    }

    /// The 8 header bytes, or `badRung` when `rung` does not fit its four bits.
    func encoded() throws(FramingError) -> Data {
        guard rung <= 15 else { throw .badRung }
        var byte0 = (Self.version << 6) | (type.rawValue << 4)
        if keyframe { byte0 |= 0x08 }
        if paramSets { byte0 |= 0x04 }
        if rungChanged { byte0 |= 0x02 }
        return Data([byte0, rung << 4] + seq.littleEndianBytes + ptsMs.littleEndianBytes)
    }
}

extension FixedWidthInteger where Self: UnsignedInteger {
    /// Reads the value from the first `bitWidth / 8` bytes of `bytes`, least significant
    /// first; the caller has checked that they are there.
    init(littleEndianBytes bytes: some Collection<UInt8>) {
        self = bytes.prefix(Self.bitWidth / 8).reversed().reduce(0) { ($0 << 8) | Self($1) }
    }

    /// The value as `bitWidth / 8` bytes, least significant first.
    var littleEndianBytes: [UInt8] {
        (0..<(Self.bitWidth / 8)).map { UInt8(truncatingIfNeeded: self >> ($0 * 8)) }
    }
}
