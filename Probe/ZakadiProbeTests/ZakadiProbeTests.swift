import Foundation
import XCTest
@_spi(Testing) import ZakadiSDK
@_spi(Testing) import ZakadiSDKTesting

@testable import ZakadiProbe

/// The app's run on the simulator, which has no camera: over the synthetic source, over the
/// camera, and over a stub standing for the camera. `ci.yml` runs them in the `integration`
/// job; each removes the log it wrote.
final class ZakadiProbeTests: XCTestCase {
    @MainActor
    func testTheScreenIsMade() {
        XCTAssertNoThrow(ContentView())
    }

    /// Spec 09 9.11 item 6, D105: `Documents/zakadi-probe/probe-<unix ms>.jsonl` in format 1
    /// with `platform` `ios`, one `run` and one `run_end` per run of schedule 1, shortened.
    @MainActor
    func testARunOverTheSyntheticSourceWritesFormatOneInDocuments() async throws {
        let schedule = ProbeSchedule.one.shortened(by: 20)
        let model = ProbeModel(schedule: schedule)
        await model.run(SyntheticFrameSource(), name: "synthetic", preference: .any)
        let url = try XCTUnwrap(model.log)
        removeAfterwards(url)
        XCTAssertEqual(model.phase, .ended("done"))
        XCTAssertEqual(
            url.deletingLastPathComponent().resolvingSymlinksInPath().path,
            ProbeModel.logDirectory.resolvingSymlinksInPath().path)
        let path = try XCTUnwrap(model.logPath)
        let prefix = "Documents/zakadi-probe/probe-"
        XCTAssertTrue(path.hasPrefix(prefix) && path.hasSuffix(".jsonl"), path)
        let millis = try XCTUnwrap(Int(path.dropFirst(prefix.count).dropLast(".jsonl".count)))
        let log = try ProbeLog(url)
        let device = try XCTUnwrap(log.lines.first)
        XCTAssertEqual(device["kind"] as? String, "device")
        XCTAssertEqual(device["platform"] as? String, "ios")
        XCTAssertEqual(device["wall_ms"] as? Int, millis, "the file is named by the run's start")
        XCTAssertEqual(device["schedule"] as? Int, 1)
        XCTAssertEqual((device["args"] as? [String: Any])?["source"] as? String, "synthetic")
        let end = try XCTUnwrap(log.lines.last)
        XCTAssertEqual(end["kind"] as? String, "end")
        XCTAssertEqual(end["reason"] as? String, "done")
        XCTAssertEqual(end["runs"] as? Int, schedule.runs.count)
        XCTAssertEqual(log.lines("device").count, 1)
        XCTAssertEqual(log.lines("end").count, 1)
        XCTAssertEqual(log.lines("run").count, schedule.runs.count)
        XCTAssertEqual(log.lines("run_end").count, schedule.runs.count)
        XCTAssertEqual(model.progress.runsBegun, schedule.runs.count)
        XCTAssertEqual(model.progress.runsEnded, schedule.runs.count)
    }

    /// Spec 07 7.3, 7.12: without a front camera, as on the simulator, a camera run logs
    /// `front_camera` false and ends `unsupported_device` without asking for the camera.
    @MainActor
    func testWithoutAFrontCameraACameraRunEndsUnsupportedDevice() async throws {
        try XCTSkipIf(FrontCameraSource.available, "the device has a front camera")
        let model = ProbeModel()
        await model.runCamera()
        let url = try XCTUnwrap(model.log)
        removeAfterwards(url)
        XCTAssertEqual(model.phase, .ended("unsupported_device"))
        let log = try ProbeLog(url)
        XCTAssertEqual(log.lines.compactMap { $0["kind"] as? String }, ["device", "end"])
        let device = try XCTUnwrap(log.lines.first)
        XCTAssertEqual(device["front_camera"] as? Bool, false)
        XCTAssertEqual(device["tier"] as? String, "U")
        XCTAssertEqual((device["args"] as? [String: Any])?["source"] as? String, "camera")
        let end = try XCTUnwrap(log.lines.last)
        XCTAssertEqual(end["reason"] as? String, "unsupported_device")
        XCTAssertEqual(end["runs"] as? Int, 0)
    }

    /// Spec 07 7.29, 05 5.3: a run copies its source's applied rotation angle, bias and clock
    /// into `run.camera`, here from a stub behind the front camera check of the camera run.
    @MainActor
    func testARunCopiesItsSourcesRotationBiasAndClockIntoRunCamera() async throws {
        var schedule = ProbeSchedule.one.shortened(by: 20)
        schedule.runs = Array(schedule.runs.prefix(1))
        let formats = [
            CaptureFormat(
                width: 480, height: 640, rotation: 90, fps: 15...30, exposureBias: 0.3,
                hostClock: true),
            CaptureFormat(
                width: 480, height: 640, rotation: 270, fps: 15...24, exposureBias: nil,
                hostClock: false),
        ]
        for format in formats {
            let model = ProbeModel(schedule: schedule)
            let camera = FrontCameraSource(StubCamera(format), present: true)
            await model.run(camera, name: "camera", preference: .any)
            let url = try XCTUnwrap(model.log)
            removeAfterwards(url)
            let run = try XCTUnwrap(ProbeLog(url).lines("run").first)
            let logged = try XCTUnwrap(run["camera"] as? [String: Any])
            XCTAssertEqual(logged["w"] as? Int, format.width)
            XCTAssertEqual(logged["h"] as? Int, format.height)
            XCTAssertEqual(logged["rotation"] as? Int, format.rotation)
            XCTAssertEqual(logged["fps_min"] as? Double, format.minFps)
            XCTAssertEqual(logged["fps_max"] as? Double, format.maxFps)
            if let bias = format.exposureBias {
                XCTAssertEqual(
                    try XCTUnwrap(logged["ev"] as? Double), Double(bias), accuracy: 0.001)
            } else {
                XCTAssertTrue(logged["ev"] is NSNull, "no bias applied")
            }
            XCTAssertEqual(logged["clock"] as? String, format.hostClock ? "host" : "other")
            XCTAssertEqual(
                run["t0_us"] is NSNull, !format.hostClock, "t0_us on the host clock only")
        }
    }

    private func removeAfterwards(_ url: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }
}
