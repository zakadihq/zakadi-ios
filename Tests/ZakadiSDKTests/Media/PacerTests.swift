import CoreMedia
import XCTest

@_spi(Testing) @testable import ZakadiSDK

/// The pacer of spec 07 7.18 on fixed frame times (7.29: iOS matches Android).
final class PacerTests: XCTestCase {
    /// The indices of `times` the pacer keeps.
    private func kept(_ pacer: inout Pacer, _ times: [CMTime]) -> [Int] {
        times.indices.filter { pacer.decide(times[$0]) == .keep }
    }

    private func thirtyFps(_ count: Int) -> [CMTime] {
        (0..<count).map { MediaFixtures.time($0) }
    }

    func testThirtyFpsIsPacedToEachRungRate() {
        let expected: [Int: [Int]] = [
            20: (0..<30).filter { $0 % 3 != 1 },
            15: (0..<30).filter { $0 % 2 == 0 },
            12: (0..<30).filter { [0, 3].contains($0 % 5) },
            10: (0..<30).filter { $0 % 3 == 0 },
        ]
        for (fps, indices) in expected {
            var pacer = Pacer(fps: fps)
            XCTAssertEqual(kept(&pacer, thirtyFps(30)), indices, "\(fps) fps")
        }
    }

    func testAFrameUpTo3MsEarlyFillsItsSlot() {
        var pacer = Pacer(fps: 10)
        let times = [0, 97.5, 196.5, 200, 297].map {
            CMTime(seconds: $0 / 1000, preferredTimescale: 1_000_000)
        }
        XCTAssertEqual(
            times.map { pacer.decide($0) }, [.keep, .keep, .pacing, .keep, .keep])
    }

    func testAStallRestartsTheSlotsWithoutABurst() {
        var pacer = Pacer(fps: 15)
        let times = [0, 1, 2, 3] + (33...40)
        XCTAssertEqual(
            times.map { pacer.decide(MediaFixtures.time($0)) },
            [
                .keep, .pacing, .keep, .pacing, .keep, .pacing, .keep, .pacing, .keep, .pacing,
                .keep, .pacing,
            ])
    }

    func testDecimationDropsEvery4thOr2ndKeptFrame() {
        var one = Pacer(fps: 30, decimation: 1)
        XCTAssertEqual(
            thirtyFps(8).map { one.decide($0) },
            [.keep, .keep, .keep, .decimation, .keep, .keep, .keep, .decimation])
        var two = Pacer(fps: 30, decimation: 2)
        XCTAssertEqual(
            thirtyFps(4).map { two.decide($0) }, [.keep, .decimation, .keep, .decimation])
    }

    func testDecimationCountsTheFramesThePacingKept() {
        var pacer = Pacer(fps: 15, decimation: 2)
        XCTAssertEqual(
            thirtyFps(8).map { pacer.decide($0) },
            [.keep, .pacing, .decimation, .pacing, .keep, .pacing, .decimation, .pacing])
    }

    func testANewLevelCountsAfresh() {
        var pacer = Pacer(fps: 30, decimation: 1)
        let times = thirtyFps(8)
        XCTAssertEqual(times[0..<3].map { pacer.decide($0) }, [.keep, .keep, .keep])
        pacer.setDecimation(2)
        XCTAssertEqual(times[3..<6].map { pacer.decide($0) }, [.keep, .decimation, .keep])
        pacer.setDecimation(0)
        XCTAssertEqual(times[6..<8].map { pacer.decide($0) }, [.keep, .keep])
    }
}
