import CoreMedia
import CoreVideo
import XCTest

@_spi(Testing) @testable import ZakadiSDK

/// The capture settings of spec 07 7.29 and 7.8 (spec 05 5.3).
final class CaptureSettingsTests: XCTestCase {
    private let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    private func format(
        _ width: Int32, _ height: Int32, _ pixelFormat: FourCharCode
    ) -> FormatCandidate {
        FormatCandidate(width: width, height: height, pixelFormat: pixelFormat)
    }

    func testTheSmallest420vFormatAtOrAbove640x480IsTaken() {
        let list = [
            format(640, 480, full), format(352, 288, video), format(1280, 720, video),
            format(640, 480, video), format(1920, 1080, video),
        ]
        XCTAssertEqual(CaptureSettings.bestFormat(list, width: 640, height: 480), 3)
    }

    func testTheLargest420vFormatIsTakenWhenNoneIsLargeEnough() {
        let list = [format(352, 288, video), format(480, 360, video), format(1920, 1080, full)]
        XCTAssertEqual(CaptureSettings.bestFormat(list, width: 640, height: 480), 1)
    }

    func testTheFirstListedWinsATie() {
        let above = [format(1280, 720, video), format(1280, 720, video)]
        XCTAssertEqual(CaptureSettings.bestFormat(above, width: 640, height: 480), 0)
        let below = [format(352, 288, video), format(352, 288, video)]
        XCTAssertEqual(CaptureSettings.bestFormat(below, width: 640, height: 480), 0)
    }

    func testNo420vFormatIsNoChoice() {
        let list = [format(640, 480, full)]
        XCTAssertNil(CaptureSettings.bestFormat(list, width: 640, height: 480))
    }

    func testFrameDurationsRunFromOneOverMaxFpsToOneFifteenthOfASecond() {
        let wide = [
            FrameDurations(
                min: CMTime(value: 1, timescale: 60), max: CMTime(value: 1, timescale: 1))
        ]
        XCTAssertEqual(
            CaptureSettings.frameDurations(maxFps: 30, supported: wide),
            FrameDurations(
                min: CMTime(value: 1, timescale: 30), max: CMTime(value: 1, timescale: 15)))
        XCTAssertEqual(
            CaptureSettings.frameDurations(maxFps: 24, supported: wide).min,
            CMTime(value: 1, timescale: 24))
    }

    func testFrameDurationsStayInsideTheSupportedRanges() {
        let narrow = [
            FrameDurations(
                min: CMTime(value: 1, timescale: 25), max: CMTime(value: 1, timescale: 20))
        ]
        XCTAssertEqual(
            CaptureSettings.frameDurations(maxFps: 30, supported: narrow),
            FrameDurations(
                min: CMTime(value: 1, timescale: 25), max: CMTime(value: 1, timescale: 20)))
        let split = [
            FrameDurations(
                min: CMTime(value: 1, timescale: 30), max: CMTime(value: 1, timescale: 24)),
            FrameDurations(
                min: CMTime(value: 1, timescale: 12), max: CMTime(value: 1, timescale: 2)),
        ]
        XCTAssertEqual(
            CaptureSettings.frameDurations(maxFps: 60, supported: split),
            FrameDurations(
                min: CMTime(value: 1, timescale: 30), max: CMTime(value: 1, timescale: 12)))
    }

    func testExposureBiasIsPlusThreeTenthsWithinTheDeviceRange() {
        XCTAssertEqual(CaptureSettings.exposureBias(min: -8, max: 8), 0.3)
        XCTAssertEqual(CaptureSettings.exposureBias(min: -2, max: 0.2), 0.2)
        XCTAssertEqual(CaptureSettings.exposureBias(min: 0.5, max: 2), 0.5)
    }
}
