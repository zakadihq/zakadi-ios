import Foundation

/// One binary media message (spec 01 1.3): the 8-byte header, then the payload.
struct MediaMessage: Equatable {
    let header: MediaHeader
    /// The message as it is sent and hashed into the chain: header bytes, then payload.
    let bytes: Data

    /// Everything after the header.
    var payload: Data {
        Data(bytes.dropFirst(MediaHeader.length))
    }

    /// A message to send, or `badRung` when the header's rung does not fit its field.
    init(header: MediaHeader, payload: Data) throws(FramingError) {
        self.header = header
        bytes = try header.encoded() + payload
    }

    /// Decodes a message and checks the payload the framing defines (spec 01 1.3.2): a
    /// probe carries its 8-byte send time and an audio batch parses into ordered records.
    init(decoding bytes: Data) throws(FramingError) {
        header = try MediaHeader(decoding: bytes)
        self.bytes = Data(bytes)
        switch header.type {
        case .video, .audio:
            break
        case .probe:
            _ = try ProbePayload(parsing: payload)
        case .audioBatch:
            _ = try AudioBatchPayload(parsing: payload)
        }
    }
}

/// The payload of a probe (spec 01 1.3.2, type 2): the client monotonic send time in
/// microseconds as uint64 little-endian, then random filler up to `probe.bytes`.
struct ProbePayload: Equatable {
    var sendTimeUs: UInt64

    init(parsing payload: Data) throws(FramingError) {
        guard payload.count >= 8 else { throw .shortProbe }
        sendTimeUs = UInt64(littleEndianBytes: payload)
    }
}

/// The payload of an audio batch (spec 01 1.3.2, type 3): records of
/// `uint16 len | uint16 pts_delta_ms | packet`, ordered by `pts_delta_ms`.
struct AudioBatchPayload: Equatable {
    /// One packet and its offset from the header's `pts_ms`.
    struct Record: Equatable {
        var ptsDeltaMs: UInt16
        var packet: Data
    }

    var records: [Record]

    init(parsing payload: Data) throws(FramingError) {
        let bytes = [UInt8](payload)
        var records: [Record] = []
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else { throw .truncatedBatchRecord }
            let length = Int(UInt16(littleEndianBytes: bytes[offset..<(offset + 2)]))
            let ptsDeltaMs = UInt16(littleEndianBytes: bytes[(offset + 2)..<(offset + 4)])
            offset += 4
            guard bytes.count - offset >= length else { throw .truncatedBatchRecord }
            if let last = records.last, ptsDeltaMs < last.ptsDeltaMs { throw .batchOutOfOrder }
            let packet = Data(bytes[offset..<(offset + length)])
            records.append(Record(ptsDeltaMs: ptsDeltaMs, packet: packet))
            offset += length
        }
        guard !records.isEmpty else { throw .emptyBatch }
        self.records = records
    }
}
