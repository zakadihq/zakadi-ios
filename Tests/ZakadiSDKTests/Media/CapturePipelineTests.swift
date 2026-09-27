import CoreMedia
import XCTest

@_spi(Testing) @testable import ZakadiSDK

/// The capture pipeline of spec 07 7.29 over a source the test drives, frame by frame.
final class CapturePipelineTests: XCTestCase {
    private var events: [PipelineEvent] = []
    private var source = ManualFrameSource()
    private lazy var pipeline = CapturePipeline(source: source) { [unowned self] event, _ in
        events.append(event)
    }

    override func setUp() {
        super.setUp()
        events = []
        source = ManualFrameSource()
    }

    /// Runs `body` on the pipeline's queue, then lets the encoder's outputs arrive.
    private func onQueue(_ body: () throws -> Void) throws {
        try pipeline.queue.sync(execute: body)
        pipeline.queue.sync {}
    }

    private var outputs: [EncodedFrame] {
        events.compactMap {
            if case .output(let frame) = $0 { return frame }
            return nil
        }
    }

    private var drops: [DropReason] {
        events.compactMap {
            if case .dropped(_, let reason) = $0 { return reason }
            return nil
        }
    }

    func testPacingAndDecimationDropFramesBeforeTheEncoder() throws {
        try onQueue {
            try pipeline.startCapture()
            try pipeline.startEncoder(MediaFixtures.settings(rung: 2))
            for index in 0..<8 { try source.push(index) }
            pipeline.setDecimation(1)
            for index in 8..<24 { try source.push(index) }
            pipeline.stopEncoder()
        }
        XCTAssertEqual(drops.filter { $0 == .pacing }.count, 12, "15 of 30 fps")
        XCTAssertEqual(drops.filter { $0 == .decimation }.count, 2, "every 4th of 8 kept")
        XCTAssertEqual(outputs.count, 10)
    }

    func testMaxFpsCapsTheRungRate() throws {
        pipeline = CapturePipeline(source: source, maxFps: 10) { [unowned self] event, _ in
            events.append(event)
        }
        try onQueue {
            try pipeline.startCapture()
            try pipeline.startEncoder(MediaFixtures.settings(rung: 0))
            for index in 0..<30 { try source.push(index) }
            pipeline.stopEncoder()
        }
        XCTAssertEqual(outputs.count, 10, "rung 0's 20 fps capped at 10")
    }

    func testAKeyframeRequestForcesTheNextSubmittedFrame() throws {
        try onQueue {
            try pipeline.startCapture()
            try pipeline.startEncoder(MediaFixtures.settings(rung: 2))
            for index in 0..<10 { try source.push(index) }
            pipeline.requestKeyframe()
            try source.push(10)
            try source.push(11)
            pipeline.stopEncoder()
        }
        XCTAssertEqual(outputs.map(\.isIDR), [true, false, false, false, false, true])
        XCTAssertTrue(events.contains { if case .keyframeRequested = $0 { true } else { false } })
    }

    func testASizeChangeRecreatesTheSessionFromAnIDR() throws {
        try onQueue {
            try pipeline.startCapture()
            try pipeline.startEncoder(MediaFixtures.settings(rung: 2))
            for index in 0..<10 { try source.push(index) }
            try pipeline.changeRung(MediaFixtures.settings(rung: 3))
            try source.push(10)
        }
        try onQueue {
            for index in 11..<20 { try source.push(index) }
            pipeline.stopEncoder()
        }
        XCTAssertEqual(drops.filter { $0 == .noEncoder }.count, 1, "the frame in between")
        let stopped = try XCTUnwrap(
            events.firstIndex { if case .encoderStopped = $0 { true } else { false } })
        let started = events.indices.filter {
            if case .encoderStarted = events[$0] { true } else { false }
        }
        XCTAssertEqual(started.count, 2)
        XCTAssertLessThan(stopped, started[1], "the old session ends before the new starts")
        let after = events[started[1]...].compactMap {
            if case .output(let frame) = $0 { return frame }
            return nil
        }
        let first = try XCTUnwrap(after.first)
        XCTAssertTrue(first.isIDR)
        XCTAssertEqual([first.width, first.height], [336, 448])
        let sets = events[started[1]...].contains {
            if case .parameterSets = $0 { true } else { false }
        }
        XCTAssertTrue(sets, "the new session's SPS and PPS")
    }

    func testTheSameSizeKeepsTheEncoderWithTheNewRateAndBitrate() throws {
        try onQueue {
            try pipeline.startCapture()
            try pipeline.startEncoder(MediaFixtures.settings(rung: 0))
            try pipeline.changeRung(MediaFixtures.settings(rung: 1))
            pipeline.stopEncoder()
        }
        let started = events.filter { if case .encoderStarted = $0 { true } else { false } }
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(
            events.contains { if case .bitrateRequested(600) = $0 { true } else { false } })
    }
}
