import XCTest

@_spi(Testing) @testable import ZakadiSDK
@_spi(Testing) @testable import ZakadiSDKTesting

/// Schedule 1 of Z-064's Spec and what a run does on frame and IDR times alone.
final class ProbeScheduleTests: XCTestCase {
    func testScheduleOneRunsTheLadderThenTheStep() {
        let schedule = ProbeSchedule.one
        XCTAssertEqual(schedule.number, 1)
        XCTAssertEqual(schedule.gopMs, 2_000)
        XCTAssertEqual(schedule.keyframeDelayMs, 1_000)
        XCTAssertEqual(schedule.runs.map(\.rung.index), [0, 1, 2, 3, 4, 2])
        XCTAssertEqual(
            schedule.runs.map(\.durationMs), [20_000, 20_000, 60_000, 20_000, 20_000, 18_000])
        XCTAssertEqual(schedule.runs.map(\.mode), Array(repeating: .constant, count: 5) + [.step])
        XCTAssertEqual(
            schedule.runs.map(\.keyframeRequests), [true, true, true, true, true, false])
        XCTAssertEqual(
            schedule.runs[5].rateSteps,
            [ProbeSchedule.RateStep(atMs: 6_000, kbps: 200), .init(atMs: 12_000, kbps: 400)])
        XCTAssertEqual(schedule.runs[5].rung, Rung.exampleLadder[2])
    }

    func testAShortenedScheduleDividesDurationsAndStepTimes() {
        let short = ProbeSchedule.one.shortened(by: 10)
        XCTAssertEqual(short.divisor, 10)
        XCTAssertEqual(short.runs.map(\.durationMs), [2_000, 2_000, 6_000, 2_000, 2_000, 1_800])
        XCTAssertEqual(short.runs[5].rateSteps.map(\.atMs), [600, 1_200])
        XCTAssertEqual(short.gopMs, 2_000)
        XCTAssertEqual(short.keyframeDelayMs, 1_000)
    }

    func testAConstantRunRequestsAKeyframeASecondAfterEveryUnansweredIDR() {
        var run = RunController(run: ProbeSchedule.one.runs[0], keyframeDelayMs: 1_000)
        XCTAssertEqual(run.frame(at: 0), [], "nothing before the first IDR")
        run.idr(at: 0)
        XCTAssertEqual(run.frame(at: 950_000), [])
        XCTAssertEqual(run.frame(at: 1_000_000), [.requestKeyframe])
        XCTAssertEqual(run.frame(at: 1_050_000), [], "one request per unanswered IDR")
        run.idr(at: 1_050_000)
        XCTAssertEqual(run.frame(at: 2_100_000), [], "an answering IDR schedules none")
        run.idr(at: 3_050_000)
        XCTAssertEqual(run.frame(at: 4_000_000), [])
        XCTAssertEqual(run.frame(at: 4_050_000), [.requestKeyframe])
        XCTAssertEqual(run.frame(at: 19_950_000), [])
        XCTAssertEqual(run.frame(at: 20_000_000), [.end], "20 s from the first IDR")
        XCTAssertEqual(run.frame(at: 20_050_000), [])
    }

    func testTheStepRunChangesTheBitrateAtSixAndTwelveSeconds() {
        var run = RunController(run: ProbeSchedule.one.runs[5], keyframeDelayMs: 1_000)
        run.idr(at: 500_000)
        var actions: [Int64: [RunController.Action]] = [:]
        for time in stride(from: Int64(500_000), through: 18_500_000, by: 50_000) {
            let now = run.frame(at: time)
            if !now.isEmpty { actions[time] = now }
        }
        XCTAssertEqual(
            actions,
            [6_500_000: [.setBitrate(200)], 12_500_000: [.setBitrate(400)], 18_500_000: [.end]])
    }
}
