import Dispatch
import Foundation
@_spi(Testing) import ZakadiSDK

/// How a probe runs and what its `device` line records as `args`.
@_spi(Testing) public struct ProbeOptions: Sendable {
    /// Where `probe-<unix ms>.jsonl` is written.
    public var directory: URL
    /// What `args` calls the frame source, as `camera` or `synthetic`.
    public var sourceName: String
    public var schedule: ProbeSchedule
    public var preference: EncoderPreference
    /// `device_quirks.max_fps`.
    public var maxFps: Int

    public init(
        directory: URL, sourceName: String, schedule: ProbeSchedule = .one,
        preference: EncoderPreference = .hardware, maxFps: Int = 30
    ) {
        self.directory = directory
        self.sourceName = sourceName
        self.schedule = schedule
        self.preference = preference
        self.maxFps = maxFps
    }

    /// The `args` of the `device` line.
    public var args: JSONValue {
        .fields([
            "source": .string(sourceName), "encoder": .string(preference.rawValue),
            "max_fps": .of(maxFps), "divisor": .of(schedule.divisor),
        ])
    }
}

/// Runs a probe schedule through the capture pipeline over any frame source and writes
/// one log in format 1 (phase 0 measurement 6, spec 09 9.11 item 6, D105).
///
/// The source runs for the whole probe; each run starts a new encoder at its rung and ends
/// with the encoder's last output. A run that has not ended 10 s after its duration ends
/// with the error `timeout`.
@_spi(Testing) public final class ProbeRunner: @unchecked Sendable {
    public let options: ProbeOptions
    private let pipeline: CapturePipeline
    private var file: FileHandle?
    private var url: URL?
    private var origin: Int64 = 0
    private var completed = 0
    private var current: RunRecorder?
    private var ticker: DispatchSourceTimer?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var failure: (any Error)?

    public init(source: any FrameSource, options: ProbeOptions) {
        self.options = options
        let relay = EventRelay()
        pipeline = CapturePipeline(source: source, maxFps: options.maxFps) { event, time in
            relay.runner?.handle(event, at: time)
        }
        relay.runner = self
    }

    /// Runs the schedule; returns the log once its `end` line is written.
    public func run() async throws -> URL {
        let facts = await DeviceFacts.collect(preference: options.preference)
        let url = options.directory.appendingPathComponent("probe-\(facts.wallMs).jsonl")
        try FileManager.default.createDirectory(
            at: options.directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let file = try FileHandle(forWritingTo: url)
        return try await withCheckedThrowingContinuation { continuation in
            pipeline.queue.async { [self] in
                self.file = file
                self.url = url
                self.continuation = continuation
                begin(facts)
            }
        }
    }

    private func begin(_ facts: DeviceFacts) {
        origin = HostClock.nowMicroseconds
        write(ProbeLine.device(facts, schedule: options.schedule.number, args: options.args))
        do throws(FrameSourceError) {
            try pipeline.startCapture()
        } catch {
            return finish(error == .unavailable ? .unsupportedDevice : .error)
        }
        startRun(0)
    }

    private func startRun(_ index: Int) {
        let run = options.schedule.runs[index]
        let recorder = RunRecorder(
            index: index,
            controller: RunController(run: run, keyframeDelayMs: options.schedule.keyframeDelayMs))
        current = recorder
        let settings = EncoderSettings(
            rung: run.rung, gopMs: options.schedule.gopMs, preference: options.preference)
        do throws(EncoderError) {
            try pipeline.startEncoder(settings)
        } catch {
            current = nil
            return finish(.error)
        }
        let limit = Double(run.durationMs) / 1000 + 10
        pipeline.queue.asyncAfter(deadline: .now() + limit) { [weak self, weak recorder] in
            guard let self, let recorder, current === recorder, !recorder.ending else { return }
            recorder.error = "timeout"
            endRun(recorder)
        }
    }

    fileprivate func handle(_ event: PipelineEvent, at time: Int64) {
        guard let recorder = current else { return }
        let now = time - origin
        switch event {
        case .captured(let pts):
            recorder.window.captured += 1
            control(recorder, at: HostClock.microseconds(pts))
        case .dropped(_, let reason):
            if reason != .noEncoder { recorder.preEncodeDrops += 1 }
        case .submitted(let pts):
            submitted(recorder, pts: HostClock.microseconds(pts), at: now)
        case .output(let frame):
            output(recorder, frame, at: now)
        case .encodeFailed(_, let status):
            recorder.error = recorder.error ?? "encode \(status)"
        case .encoderDropped:
            recorder.encoderDropped += 1
        default:
            handleEncoder(event, recorder, at: now)
        }
    }

    private func handleEncoder(_ event: PipelineEvent, _ recorder: RunRecorder, at now: Int64) {
        switch event {
        case .encoderStarted(let report):
            recorder.report = report
        case .encoderStopped:
            finishRun(recorder, at: now)
        case .encoderFailed(let error):
            recorder.error = "\(error.operation) \(error.status)"
        case .parameterSets(let sets):
            write(ProbeLine.params(run: recorder.index, sets: sets, at: now))
        case .keyframeRequested:
            recorder.requests += 1
            recorder.records.append(.keyframeRequest(time: now, repeated: false))
            write(
                ProbeLine.keyframeRequest(run: recorder.index, number: recorder.requests, at: now))
        case .bitrateRequested(let kbps):
            write(ProbeLine.rate(run: recorder.index, kbps: kbps, at: now))
        default:
            break
        }
    }

    private func control(_ recorder: RunRecorder, at pts: Int64) {
        for action in recorder.controller.frame(at: pts) {
            switch action {
            case .requestKeyframe:
                pipeline.requestKeyframe()
            case .setBitrate(let kbps):
                do throws(EncoderError) {
                    try pipeline.setBitrate(kbps: kbps)
                } catch {
                    recorder.error = recorder.error ?? "\(error.operation) \(error.status)"
                }
            case .end:
                endRun(recorder)
            }
        }
    }

    private func submitted(_ recorder: RunRecorder, pts: Int64, at now: Int64) {
        if recorder.origin == nil {
            recorder.origin = pts
            writeRunLine(recorder, at: now)
            startTicker(recorder)
        }
        let relative = recorder.input(now, pts: pts)
        write(ProbeLine.input(run: recorder.index, pts: relative, at: now))
    }

    private func output(_ recorder: RunRecorder, _ frame: EncodedFrame, at now: Int64) {
        let pts = HostClock.microseconds(frame.presentationTime)
        let relative = recorder.output(now, pts: pts, frame: frame)
        write(ProbeLine.output(run: recorder.index, pts: relative, frame: frame, at: now))
        if frame.nalTypes.contains(5) { recorder.controller.idr(at: pts) }
    }

    private func writeRunLine(_ recorder: RunRecorder, at now: Int64) {
        guard let report = recorder.report else { return }
        let camera = pipeline.source.format
        let description = RunDescription(
            index: recorder.index, run: recorder.controller.run, gopMs: options.schedule.gopMs,
            report: report, camera: camera,
            firstFrame: camera?.hostClock == true ? recorder.origin.map { $0 - origin } : nil,
            thermal: DeviceFacts.thermalState())
        write(ProbeLine.run(description, at: now))
    }

    private func endRun(_ recorder: RunRecorder) {
        recorder.ending = true
        stopTicker()
        pipeline.stopEncoder()
    }

    private func finishRun(_ recorder: RunRecorder, at now: Int64) {
        stopTicker()
        if recorder.origin == nil { writeRunLine(recorder, at: now) }
        write(ProbeLine.runEnd(run: recorder.index, totals: recorder.finish(), at: now))
        completed += 1
        current = nil
        if recorder.index + 1 < options.schedule.runs.count {
            startRun(recorder.index + 1)
        } else {
            finish(.done)
        }
    }

    private func startTicker(_ recorder: RunRecorder) {
        recorder.cpuMark = RunRecorder.cpuTime()
        let timer = DispatchSource.makeTimerSource(queue: pipeline.queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak recorder] in
            guard let self, let recorder else { return }
            write(
                ProbeLine.tick(
                    run: recorder.index, counts: recorder.tick(),
                    at: HostClock.nowMicroseconds - origin))
        }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func finish(_ reason: EndReason) {
        stopTicker()
        pipeline.stopCapture()
        let runs = completed
        Task { [self] in
            let battery = await Battery.read()
            pipeline.queue.async { [self] in
                let now = HostClock.nowMicroseconds - origin
                write(
                    ProbeLine.end(
                        runs: runs, reason: reason, thermal: DeviceFacts.thermalState(),
                        battery: battery, at: now))
                try? file?.close()
                if let failure {
                    continuation?.resume(throwing: failure)
                } else if let url {
                    continuation?.resume(returning: url)
                }
                continuation = nil
            }
        }
    }

    private func write(_ line: JSONValue) {
        guard failure == nil, let file else { return }
        do {
            try file.write(contentsOf: Data((line.serialized + "\n").utf8))
        } catch {
            failure = error
        }
    }
}

/// Lets the pipeline's listener reach the runner that owns the pipeline.
private final class EventRelay: @unchecked Sendable {
    weak var runner: ProbeRunner?
}
