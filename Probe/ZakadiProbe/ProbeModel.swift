import AVFoundation
import Foundation
import UIKit
@_spi(Testing) import ZakadiSDK
@_spi(Testing) import ZakadiSDKTesting

/// The probe's run (phase 0 measurement 6, spec 09 9.11 item 6, D105): schedule 1 through
/// the runner of `ZakadiSDKTesting`, one log in format 1 (D120) per run in
/// `Documents/zakadi-probe/`, the screen kept on while it runs.
@MainActor
final class ProbeModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case running
        /// The reason the log's `end` line gives: `done`, `unsupported_device` or `error`.
        case ended(String)
        /// The camera permission was refused, so nothing ran (spec 07 7.3).
        case denied
        /// The log could not be written.
        case failed(String)
    }

    /// `Documents/zakadi-probe/`, which the Files app shows under On My iPhone.
    nonisolated static var logDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("zakadi-probe", isDirectory: true)
    }

    let schedule: ProbeSchedule
    let directory = ProbeModel.logDirectory
    @Published private(set) var phase = Phase.ready
    /// The session of the camera source, which the preview shows.
    @Published private(set) var session: AVCaptureSession?
    /// The log of the current or the last run, once it exists.
    @Published private(set) var log: URL?
    @Published private(set) var progress = LogProgress()
    @Published private(set) var started: Date?
    /// The share sheet shows the log.
    @Published var sharing = false

    init(schedule: ProbeSchedule = .one) {
        self.schedule = schedule
    }

    /// The runs of the schedule.
    var runCount: Int {
        schedule.runs.count
    }

    /// The log's path in the app's container: `Documents/zakadi-probe/probe-<unix ms>.jsonl`.
    var logPath: String? {
        guard let log else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        let path = log.resolvingSymlinksInPath().path
        return path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
    }

    /// The run button: schedule 1 on Z-068's camera source. The front camera is checked
    /// before the permission is asked (spec 07 7.3), so a device without one ends
    /// `unsupported_device` unasked (7.12).
    func runCamera() async {
        guard phase != .running else { return }
        phase = .running
        let present = FrontCameraSource.available
        if present {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                phase = .denied
                return
            }
        }
        let camera = CameraFrameSource()
        session = camera.session
        await run(
            FrontCameraSource(camera, present: present), name: "camera", preference: .hardware)
    }

    /// Runs the schedule over `source`, which the log's `args` call `name`, and offers the
    /// log in the share sheet once its `end` line is written.
    func run(_ source: any FrameSource, name: String, preference: EncoderPreference) async {
        phase = .running
        log = nil
        progress = LogProgress()
        started = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let runner = ProbeRunner(
            source: source,
            options: ProbeOptions(
                directory: directory, sourceName: name, schedule: schedule,
                preference: preference))
        let known = logNames()
        let watcher = Task { await watch(excluding: known) }
        defer { watcher.cancel() }
        do {
            let url = try await runner.run()
            log = url
            progress = LogProgress(contentsOf: url)
            phase = .ended(progress.reason ?? "unknown")
            sharing = true
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the log once a second while the run goes, for the progress on screen.
    private func watch(excluding known: Set<String>) async {
        while (try? await Task.sleep(nanoseconds: 1_000_000_000)) != nil {
            if log == nil { log = newLog(excluding: known) }
            if let log { progress = LogProgress(contentsOf: log) }
        }
    }

    private func logNames() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// The log the running probe writes: the one that was not in the directory before.
    private func newLog(excluding known: Set<String>) -> URL? {
        logNames().subtracting(known)
            .filter { $0.hasPrefix("probe-") && $0.hasSuffix(".jsonl") }
            .max()
            .map { directory.appendingPathComponent($0) }
    }
}

/// Where a log stands, from its lines: the runs begun and ended, and the reason its `end`
/// line gives. Every line of the runner opens with `v`, `kind` and `t_us`.
struct LogProgress: Equatable {
    static let runOpening = opening("run")
    static let runEndOpening = opening("run_end")
    static let endOpening = opening("end")

    var runsBegun = 0
    var runsEnded = 0
    var reason: String?

    init() {}

    init(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            if line.hasPrefix(Self.runOpening) {
                runsBegun += 1
            } else if line.hasPrefix(Self.runEndOpening) {
                runsEnded += 1
            } else if line.hasPrefix(Self.endOpening) {
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                reason = (object as? [String: Any])?["reason"] as? String
            }
        }
    }

    /// How a line of `kind` begins.
    static func opening(_ kind: String) -> String {
        "{\"v\":1,\"kind\":\"\(kind)\","
    }
}
