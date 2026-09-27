import XCTest

@_spi(Testing) @testable import ZakadiSDKTesting

/// The summaries of a `run_end` line as Z-064's Spec defines them, on synthetic lines.
final class ProbeSummaryTests: XCTestCase {
    /// Three seconds at 20 fps: an `in` line per frame at `t_us` 1 s + 50 ms per frame and
    /// its `out` 10 ms later, IDRs at frames 0, 11 and 24 (5000 bytes, others 1000),
    /// requests after frames 9 and 19 answered 2 and 5 frames later, one after frame 50
    /// never answered, and no output for frames 30 to 41 (a 600 ms stall).
    private func records() -> [ProbeRecord] {
        var records: [ProbeRecord] = []
        for frame in 0..<60 {
            let time = Int64(1_000_000 + frame * 50_000)
            let pts = Int64(frame * 50_000)
            records.append(.input(time: time, pts: pts))
            if [9, 19, 50].contains(frame) {
                records.append(.keyframeRequest(time: time + 1_000, repeated: false))
            }
            guard !(30...41).contains(frame) else { continue }
            let key = [0, 11, 24].contains(frame)
            records.append(
                .output(time: time + 10_000, pts: pts, bytes: key ? 5_000 : 1_000, key: key))
        }
        return records
    }

    func testTheSummariesOfARunWithRequestsAndAStall() throws {
        let summary = ProbeSummary(records())
        let delivered = try XCTUnwrap(summary.deliveredKbps)
        XCTAssertEqual(delivered, 480_000.0 * 1_000 / 2_950_000, accuracy: 1e-9)
        XCTAssertEqual(summary.keyframeLatencyMs, (109 + 259) / 2)
        XCTAssertEqual(summary.keyframeFrames, (2 + 5) / 2)
        XCTAssertEqual(summary.minFps, 8)
    }

    func testDeliveredBytesStartAtTheFirstKeyOutput() {
        let records: [ProbeRecord] = [
            .output(time: 0, pts: 0, bytes: 9_000, key: false),
            .output(time: 0, pts: 100_000, bytes: 1_000, key: true),
            .output(time: 0, pts: 1_100_000, bytes: 1_000, key: false),
        ]
        XCTAssertEqual(ProbeSummary(records).deliveredKbps, 16)
    }

    func testRepeatedRequestsAreLeftOut() {
        let records: [ProbeRecord] = [
            .output(time: 0, pts: 0, bytes: 1, key: true),
            .keyframeRequest(time: 10_000, repeated: false),
            .keyframeRequest(time: 20_000, repeated: true),
            .input(time: 30_000, pts: 50_000),
            .output(time: 40_000, pts: 50_000, bytes: 1, key: true),
        ]
        let summary = ProbeSummary(records)
        XCTAssertEqual(summary.keyframeLatencyMs, 30)
        XCTAssertEqual(summary.keyframeFrames, 1)
    }

    func testNoLinesGiveNoSummaries() {
        XCTAssertEqual(
            ProbeSummary([]),
            ProbeSummary(
                deliveredKbps: nil, keyframeLatencyMs: nil, keyframeFrames: nil, minFps: nil))
        let unanswered: [ProbeRecord] = [
            .output(time: 0, pts: 0, bytes: 1, key: true),
            .keyframeRequest(time: 1, repeated: false),
        ]
        XCTAssertNil(ProbeSummary(unanswered).keyframeLatencyMs)
        XCTAssertNil(ProbeSummary(unanswered).minFps, "no window fits in 0 us")
    }
}
