import CoreMedia
import Foundation

/// The SPS and PPS of a session, from its format description, and the codec string the
/// SPS gives.
@_spi(Testing) public struct ParameterSets: Sendable, Equatable {
    public var sps: Data
    public var pps: Data

    public init(sps: Data, pps: Data) {
        self.sps = sps
        self.pps = pps
    }
}

/// The three bytes after an SPS's NAL header: `profile_idc`, the constraint flags and
/// `level_idc` (ITU-T H.264 7.3.2.1.1).
@_spi(Testing) public struct SequenceParameterSet: Sendable, Equatable {
    public var profileIdc: UInt8
    public var constraintFlags: UInt8
    public var levelIdc: UInt8

    /// Reads an SPS NAL unit (type 7); nil for anything shorter or of another type.
    public init?(_ unit: Data) {
        let bytes = [UInt8](unit.prefix(4))
        guard bytes.count == 4, bytes[0] & 0x1F == 7 else { return nil }
        profileIdc = bytes[1]
        constraintFlags = bytes[2]
        levelIdc = bytes[3]
    }

    /// `config.video.codec` of spec 01 1.4: `avc1.` and the three bytes in uppercase hex.
    public var codec: String {
        "avc1."
            + [profileIdc, constraintFlags, levelIdc].map { String(format: "%02X", $0) }
            .joined()
    }

    /// The profile the SPS carries: Baseline is `profile_idc` 66 and Constrained Baseline
    /// adds `constraint_set1_flag`; nil for any other profile.
    public var profile: H264Profile? {
        guard profileIdc == 66 else { return nil }
        return constraintFlags & 0x40 != 0 ? .constrainedBaseline : .baseline
    }
}

/// One access unit out of the encoder (spec 07 7.30): what the sender sends, and what the
/// encoder returned.
@_spi(Testing) public struct EncodedFrame: Sendable {
    public var presentationTime: CMTime
    /// From the sample attachments: `NotSync` absent or false.
    public var isIDR: Bool
    /// Annex-B with 4-byte start codes, the SPS and PPS first on an IDR (spec 01 1.3.2).
    public var annexB: Data
    /// The size of the buffer the encoder returned, length-prefixed NAL units.
    public var encoderBytes: Int
    /// The NAL unit types of that buffer, in order.
    public var nalTypes: [UInt8]
    /// The session's SPS and PPS, from the format description.
    public var parameterSets: ParameterSets?
    public var width: Int
    public var height: Int

    /// Converts a compressed sample buffer; nil when it carries no data.
    public init?(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else { return kCMBlockBufferEmptyBBufErr }
            return CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: length, destination: destination)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        let (sets, lengthSize) = Self.parameterSets(format)
        let units = AnnexB.units(avcc: avcc, lengthSize: lengthSize)
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        isIDR = !notSync
        let prefix = isIDR ? [sets?.sps, sets?.pps].compactMap { $0 } : []
        annexB = AnnexB.accessUnit(prefix + units)
        encoderBytes = length
        nalTypes = units.map(AnnexB.type)
        parameterSets = sets
        width = Int(dimensions.width)
        height = Int(dimensions.height)
    }

    /// The SPS and PPS of an H.264 format description and its NAL length size.
    static func parameterSets(_ format: CMFormatDescription) -> (ParameterSets?, Int) {
        var count = 0
        var lengthSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &lengthSize)
        let sets = (0..<count).compactMap { index -> Data? in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard sets.count >= 2 else { return (nil, Int(lengthSize)) }
        return (ParameterSets(sps: sets[0], pps: sets[1]), Int(lengthSize))
    }
}

/// H.264 byte stream helpers (spec 01 1.3.2).
@_spi(Testing) public enum AnnexB {
    /// The start code before every NAL unit of a video payload.
    public static let startCode = Data([0, 0, 0, 1])

    /// The NAL units of a buffer whose units carry big-endian length prefixes of
    /// `lengthSize` bytes (AVCC), stopping at a truncated unit.
    public static func units(avcc: Data, lengthSize: Int) -> [Data] {
        let bytes = [UInt8](avcc)
        var units: [Data] = []
        var offset = 0
        while offset + lengthSize <= bytes.count {
            let length = bytes[offset..<(offset + lengthSize)].reduce(0) { $0 << 8 | Int($1) }
            offset += lengthSize
            guard length > 0, offset + length <= bytes.count else { break }
            units.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return units
    }

    /// One access unit in Annex-B: every unit behind a 4-byte start code, in order.
    public static func accessUnit(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { stream, unit in
            stream.append(startCode)
            stream.append(unit)
        }
    }

    /// `nal_unit_type`, the low five bits of a unit's first byte; 0 for an empty unit.
    public static func type(_ unit: Data) -> UInt8 {
        (unit.first ?? 0) & 0x1F
    }
}
