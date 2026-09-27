import CoreMedia
import Foundation
import VideoToolbox
import XCTest

@_spi(Testing) @testable import ZakadiSDK

/// The VideoToolbox encoder of spec 07 7.30 against this machine's H.264 encoder, which
/// may take Constrained Baseline (Apple silicon hardware) or refuse it (software).
final class VideoEncoderTests: XCTestCase {
    /// Encodes `count` frames at the settings' rate, forcing an IDR on the frames in
    /// `force`; returns the encoder, finished, and its frames in presentation order.
    private func encode(
        _ settings: EncoderSettings, count: Int, force: Set<Int> = [],
        before: (VideoEncoder, Int) throws -> Void = { _, _ in }
    ) throws -> (VideoEncoder, [EncodedFrame]) {
        let log = OutputLog()
        let encoder = try VideoEncoder(settings: settings) { log.append($0) }
        for index in 0..<count {
            try before(encoder, index)
            let frame = try MediaFixtures.movingFrame(
                index, width: settings.width, height: settings.height)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.fps))
            XCTAssertEqual(
                encoder.encode(frame, presentationTime: time, forceKeyFrame: force.contains(index)),
                noErr)
        }
        encoder.finish()
        return (encoder, log.frames.sorted { $0.presentationTime < $1.presentationTime })
    }

    func testConstrainedBaselineIsAskedFirstAndBaselineTakenWhenItIsRefused() throws {
        var asked: [String] = []
        let choice = try VideoEncoder.applyProfile { value in
            asked.append(value as String)
            return value == kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel ? -12902 : noErr
        }
        XCTAssertEqual(asked, ["H264_ConstrainedBaseline_AutoLevel", "H264_Baseline_AutoLevel"])
        XCTAssertEqual(choice.profile, .baseline)
        XCTAssertEqual(choice.refused, [.constrainedBaseline])
    }

    func testConstrainedBaselineIsKeptWhenTaken() throws {
        var asked = 0
        let choice = try VideoEncoder.applyProfile { _ in
            asked += 1
            return noErr
        }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(choice.profile, .constrainedBaseline)
        XCTAssertEqual(choice.refused, [])
    }

    func testASessionRefusingBothProfilesFails() {
        XCTAssertThrowsError(try VideoEncoder.applyProfile { _ in -12902 }) { error in
            XCTAssertEqual(
                error as? EncoderError, EncoderError(operation: "ProfileLevel", status: -12902))
        }
    }

    func testTheSPSCarriesTheProfileReportedAtLevel31OrBelow() throws {
        for rung in [0, 2, 3, 4] {
            let (encoder, frames) = try encode(MediaFixtures.settings(rung: rung), count: 3)
            let report = encoder.report
            XCTAssertEqual(report.readBack.profileLevel, report.profile.profileLevel as String)
            XCTAssertEqual(
                report.refused, report.profile == .baseline ? [.constrainedBaseline] : [])
            let sets = try XCTUnwrap(frames.first?.parameterSets, "rung \(rung)")
            let sps = try XCTUnwrap(SequenceParameterSet(sets.sps))
            XCTAssertEqual(sps.profileIdc, 66, "Baseline family, rung \(rung)")
            if report.profile == .constrainedBaseline {
                XCTAssertEqual(sps.profile, .constrainedBaseline, "rung \(rung)")
            }
            XCTAssertLessThanOrEqual(sps.levelIdc, 31, "rung \(rung)")
            XCTAssertTrue(sps.codec.hasPrefix("avc1.42"), sps.codec)
        }
    }

    func testOutputIsAnnexBWithSPSAndPPSBeforeEveryIDR() throws {
        let settings = MediaFixtures.settings(rung: 2)
        let (_, frames) = try encode(settings, count: 40, force: [9])
        XCTAssertGreaterThanOrEqual(frames.count, 38, "a real-time encoder may drop a frame")
        XCTAssertGreaterThanOrEqual(frames.filter(\.isIDR).count, 3, "first, forced and GOP")
        for frame in frames {
            let units = try Self.annexBUnits(frame.annexB)
            let types = units.map(AnnexB.type)
            if frame.isIDR {
                XCTAssertEqual(Array(types.prefix(2)), [7, 8])
                XCTAssertEqual(units[0], frame.parameterSets?.sps)
                XCTAssertEqual(units[1], frame.parameterSets?.pps)
                XCTAssertTrue(types.contains(5))
            } else {
                XCTAssertFalse(types.contains(7) || types.contains(8) || types.contains(5))
            }
            XCTAssertEqual(Array(types.drop { $0 == 7 || $0 == 8 }), frame.nalTypes)
        }
    }

    func testAForcedKeyframeLandsOnTheNextFrame() throws {
        let (_, frames) = try encode(MediaFixtures.settings(rung: 2), count: 20, force: [7, 13])
        let idr = frames.filter(\.isIDR).map { Int(($0.presentationTime.seconds * 15).rounded()) }
        XCTAssertEqual(idr, [0, 7, 13], "the frame numbers, from the presentation times")
    }

    func testABitrateChangeSetsAverageBitRateAndOneAndAHalfTimesDataRateLimits() throws {
        let settings = MediaFixtures.settings(rung: 2)
        let (encoder, _) = try encode(settings, count: 10) { encoder, index in
            if index == 5 { try encoder.setBitrate(kbps: 250) }
        }
        XCTAssertEqual(encoder.report.readBack.averageBitRate, 400_000)
        XCTAssertEqual(encoder.report.readBack.dataRateLimits, [75_000, 1])
        XCTAssertEqual(EncoderSettings.dataRateLimits(kbps: 250), [46_875, 1])
        let live = try VideoEncoder(settings: MediaFixtures.settings(rung: 2)) { _ in }
        try live.setBitrate(kbps: 250)
        XCTAssertEqual(live.readBack().averageBitRate, 250_000)
        XCTAssertEqual(live.readBack().dataRateLimits, [46_875, 1])
        live.finish()
    }

    func testTheSessionHasTheRateGOPAndRealTimeOf7_30() throws {
        let encoder = try VideoEncoder(settings: MediaFixtures.settings(rung: 0)) { _ in }
        defer { encoder.finish() }
        let readBack = encoder.report.readBack
        XCTAssertEqual(readBack.expectedFrameRate, 20)
        XCTAssertEqual(readBack.maxKeyFrameInterval, 40)
        XCTAssertEqual(readBack.maxKeyFrameIntervalDuration, 2)
        XCTAssertEqual(readBack.realTime, true)
        XCTAssertEqual(readBack.allowFrameReordering, false)
        XCTAssertNotNil(encoder.report.encoderID)
    }

    /// The units of an Annex-B stream that uses 4-byte start codes only; throws otherwise.
    static func annexBUnits(_ stream: Data) throws -> [Data] {
        let bytes = [UInt8](stream)
        let code: [UInt8] = [0, 0, 0, 1]
        let starts = bytes.indices.filter { Array(bytes[$0..<min($0 + 4, bytes.count)]) == code }
        XCTAssertEqual(starts.first, 0)
        let units = starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : bytes.count
            return Data(bytes[(starts[index] + 4)..<end])
        }
        XCTAssertEqual(AnnexB.accessUnit(units), stream)
        for unit in units {
            let unitBytes = [UInt8](unit)
            let threeByte = unitBytes.indices.contains {
                $0 + 3 <= unitBytes.count && Array(unitBytes[$0..<($0 + 3)]) == [0, 0, 1]
            }
            XCTAssertFalse(threeByte, "a 3-byte start code inside a unit")
        }
        return units
    }
}
