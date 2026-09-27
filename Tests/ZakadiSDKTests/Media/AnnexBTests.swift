import CoreMedia
import Foundation
import XCTest

@_spi(Testing) @testable import ZakadiSDK

/// The AVCC to Annex-B conversion of spec 07 7.30 and the payload of spec 01 1.3.2.
final class AnnexBTests: XCTestCase {
    /// The SPS and PPS of a 480x640 Baseline stream from VideoToolbox's software encoder.
    static let sps = Data([
        0x27, 0x42, 0xE0, 0x1E, 0xA9, 0x18, 0x3C, 0x0A, 0x36, 0x02, 0xD4, 0x08, 0x08, 0x08, 0xC2,
        0xB5, 0xEF, 0x7C, 0x04,
    ])
    static let pps = Data([0x28, 0xDE, 0x09, 0xC8])

    func testUnitsAreReadFromLengthPrefixes() {
        let avcc = Data([0, 0, 0, 2, 0x06, 0xAA, 0, 0, 0, 3, 0x65, 0x01, 0x02])
        XCTAssertEqual(
            AnnexB.units(avcc: avcc, lengthSize: 4),
            [Data([0x06, 0xAA]), Data([0x65, 0x01, 0x02])])
        XCTAssertEqual(AnnexB.units(avcc: Data([0, 5, 0x41, 0x01]), lengthSize: 2), [])
    }

    func testEveryUnitGetsAFourByteStartCode() {
        let stream = AnnexB.accessUnit([Data([0x67, 0x42]), Data([0x68]), Data([0x65, 0x88])])
        XCTAssertEqual(
            stream, Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 0x88]))
        XCTAssertEqual([Data([0x67]), Data([0x41]), Data([0x06])].map(AnnexB.type), [7, 1, 6])
    }

    func testTheSPSGivesTheCodecAndTheProfile() throws {
        let baseline = try XCTUnwrap(SequenceParameterSet(Self.sps))
        XCTAssertEqual(baseline.codec, "avc1.42E01E")
        XCTAssertEqual(baseline.profile, .constrainedBaseline)
        XCTAssertEqual(baseline.levelIdc, 30)
        let plain = try XCTUnwrap(SequenceParameterSet(Data([0x67, 0x42, 0x80, 0x1F])))
        XCTAssertEqual(plain.codec, "avc1.42801F")
        XCTAssertEqual(plain.profile, .baseline)
        XCTAssertNil(SequenceParameterSet(Data([0x67, 0x64, 0x00, 0x1F]))?.profile)
        XCTAssertNil(SequenceParameterSet(Self.pps))
    }

    func testAnIDRIsReadFromTheSampleAttachmentsNotTheSlice() throws {
        let slice = Data([0x41, 0x9A, 0x02])
        let sync = try XCTUnwrap(EncodedFrame(Self.sampleBuffer(slice, notSync: nil)))
        XCTAssertTrue(sync.isIDR)
        XCTAssertEqual(
            sync.annexB, AnnexB.accessUnit([Self.sps, Self.pps, slice]), "SPS and PPS first")
        XCTAssertEqual(sync.nalTypes, [1])
        XCTAssertEqual(sync.encoderBytes, 7)
        XCTAssertEqual(sync.parameterSets, ParameterSets(sps: Self.sps, pps: Self.pps))
        XCTAssertEqual([sync.width, sync.height], [480, 640])

        let idr = Data([0x65, 0x88, 0x84])
        let notSync = try XCTUnwrap(EncodedFrame(Self.sampleBuffer(idr, notSync: true)))
        XCTAssertFalse(notSync.isIDR)
        XCTAssertEqual(notSync.annexB, AnnexB.accessUnit([idr]), "no parameter sets")
        XCTAssertEqual(notSync.nalTypes, [5])
    }

    /// A compressed sample buffer holding `unit` behind a 4-byte length, with the SPS and
    /// PPS above in its format description and `NotSync` set when given.
    static func sampleBuffer(_ unit: Data, notSync: Bool?) throws -> CMSampleBuffer {
        var format: CMFormatDescription?
        let sets = [sps, pps]
        let status = sets[0].withUnsafeBytes { spsBytes in
            sets[1].withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes, ppsBytes].map {
                    $0.baseAddress!.assumingMemoryBound(to: UInt8.self)
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sets.map(\.count), nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        XCTAssertEqual(status, noErr)
        var avcc = Data([0, 0, 0, UInt8(unit.count)]) + unit
        var block: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
                blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        avcc.withUnsafeMutableBytes {
            _ = CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: buffer, offsetIntoDestination: 0,
                dataLength: $0.count)
        }
        var sample: CMSampleBuffer?
        var size = avcc.count
        XCTAssertEqual(
            CMSampleBufferCreateReady(
                allocator: nil, dataBuffer: buffer, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        if let notSync {
            let array = try XCTUnwrap(
                CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
            let attachments = unsafeBitCast(
                CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(notSync ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
        }
        return result
    }
}
