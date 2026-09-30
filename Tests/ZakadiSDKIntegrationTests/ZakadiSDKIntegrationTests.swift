import Foundation
import XCTest
@_spi(Testing) import ZakadiSDK
@_spi(Testing) import ZakadiSDKTesting

/// Schedule 1, shortened, on the iOS simulator over the synthetic source (spec 09 9.11
/// item 6): the log it writes parses in full, with its keyframe requests and bitrate steps
/// where the log's own times put them. `ci.yml` runs it in the `integration` job; the check
/// of those times also runs over lines built in memory, on the host under `swift test`.
final class ZakadiSDKIntegrationTests: XCTestCase {
    /// The keys of every line kind of format 1, in order (Z-064's Spec).
    static let keys: [String: [String]] = [
        "device": [
            "wall_ms", "platform", "phone", "soc", "os", "os_build", "schedule", "args", "tier",
            "low_ram", "mem_mb", "camera_level", "egl_recordable", "front_camera", "configure_ms",
            "encoders", "thermal", "battery_pct", "charging",
        ],
        "run": [
            "run", "mode", "rung", "w", "h", "fps", "kbps", "gop_ms", "path", "encoder", "hw",
            "profile", "level", "bitrate_mode", "dropped", "out_format", "camera", "t0_us",
            "thermal",
        ],
        "params": ["run", "source", "sps", "pps", "codec"],
        "in": ["run", "pts_us"],
        "out": ["run", "pts_us", "bytes", "key", "flag_key", "param_sets", "sc3", "nal"],
        "kf_req": ["run", "n", "repeat"],
        "rate": ["run", "kbps"],
        "tick": [
            "run", "captured", "submitted", "encoded", "pre_encode_drops", "enc_queue",
            "encoded_kbps", "thermal", "cpu_ms", "enc_dropped",
        ],
        "run_end": [
            "run", "in", "out", "idr", "idr_bare", "delivered_kbps", "kf_latency_ms", "kf_frames",
            "min_fps", "error",
        ],
        "end": ["runs", "reason", "thermal", "battery_pct"],
    ]

    func testShortenedScheduleOneWritesALogThatParsesInFull() async throws {
        #if !os(iOS)
            throw XCTSkip("the integration job runs this on the iOS simulator")
        #else
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zakadi-probe-\(UUID().uuidString)")
            let schedule = ProbeSchedule.one.shortened(by: 10)
            let runner = ProbeRunner(
                source: SyntheticFrameSource(),
                options: ProbeOptions(
                    directory: directory, sourceName: "synthetic", schedule: schedule,
                    preference: .any))
            let url = try await runner.run()
            XCTAssertTrue(url.lastPathComponent.hasPrefix("probe-"))
            XCTAssertEqual(url.pathExtension, "jsonl")
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.hasSuffix("\n"))
            XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII))
            let lines = try text.split(separator: "\n").map { try Self.parse(String($0)) }
            try checkOrder(lines, runs: schedule.runs.count)
            try checkDevice(lines[0])
            for run in 0..<schedule.runs.count {
                try checkRun(
                    lines.filter { $0["run"] as? Int == run }, run: run, schedule: schedule)
            }
        #endif
    }

    /// The keyframe check over run 4 built in memory. An IDR output that reaches the queue
    /// after the run's last frame puts the key `out` line after the last `in` line, and the
    /// `in` lines 1 s past its time oblige no request; with each output 10 ms after its
    /// frame, the `in` line 1 s past the key `out` line needs a `kf_req` line before it,
    /// and passes with one.
    func testAnInputASecondPastTheKeyOutputNeedsARequestBeforeIt() {
        XCTAssertEqual(Self.memoryFindings(run: 4, through: 44, lag: 2_310_000), [])
        XCTAssertEqual(
            Self.memoryFindings(run: 4, through: 20),
            ["no kf_req before the in line at t_us 1005000, 1000000 us past the first key out"])
        let request = Self.memoryLine("kf_req", 1_004_000, ["run": 4, "n": 1, "repeat": false])
        XCTAssertEqual(Self.memoryFindings(run: 4, through: 20, with: [request]), [])
    }

    /// The step check over run 5 built in memory, each output 10 ms after its frame: frames
    /// 12 and 24 are the first 600 and 1200 ms past the key `out` line. Each step's `rate`
    /// line before its frame's `in` line passes, as does the first step's line alone in a
    /// run that ends before the second step; the first step's line after frame 12's `in`
    /// line, or `rate` lines out of the steps' order, are reported.
    func testAnInputThatReachesAStepNeedsItsRateLineBeforeIt() {
        let rate = { (kbps: Int, time: Int) in
            Self.memoryLine("rate", time, ["run": 5, "kbps": kbps])
        }
        let steps = [rate(200, 604_000), rate(400, 1_204_000)]
        XCTAssertEqual(Self.memoryFindings(run: 5, through: 35, with: steps), [])
        XCTAssertEqual(Self.memoryFindings(run: 5, through: 23, with: [steps[0]]), [])
        XCTAssertEqual(
            Self.memoryFindings(run: 5, through: 35, with: [rate(200, 654_000), steps[1]]),
            ["no rate 200 before the in line at t_us 605000, 600000 us past the first key out"])
        XCTAssertEqual(
            Self.memoryFindings(
                run: 5, through: 35, with: [rate(400, 604_000), rate(200, 1_204_000)]),
            ["the rate lines [400, 200] are not a prefix of [200, 400]"])
    }

    /// One line as a dictionary, after checking its keys against its kind, in order.
    static func parse(_ line: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let fields = try XCTUnwrap(object as? [String: Any], line)
        XCTAssertEqual(fields["v"] as? Int, 1, line)
        let kind = try XCTUnwrap(fields["kind"] as? String, line)
        let keys = try XCTUnwrap(Self.keys[kind], "unknown kind \(kind)")
        XCTAssertEqual(topLevelKeys(line), ["v", "kind", "t_us"] + keys, line)
        XCTAssertNotNil(fields["t_us"] as? Int, line)
        return fields
    }

    /// The keys of a JSON object's outermost level, in the order written: the strings at
    /// depth 1 right after `{` or `,`.
    static func topLevelKeys(_ line: String) -> [String] {
        let characters = Array(line)
        var keys: [String] = []
        var depth = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                let end = closingQuote(characters, from: index)
                if depth == 1, index > 0, "{,".contains(characters[index - 1]) {
                    keys.append(String(characters[(index + 1)..<end]))
                }
                index = end + 1
                continue
            }
            if "{[".contains(character) { depth += 1 }
            if "}]".contains(character) { depth -= 1 }
            index += 1
        }
        return keys
    }

    /// The index of the quote that ends the string opening at `start`.
    static func closingQuote(_ characters: [Character], from start: Int) -> Int {
        var index = start + 1
        while index < characters.count, characters[index] != "\"" {
            index += characters[index] == "\\" ? 2 : 1
        }
        return index
    }

    private func checkOrder(_ lines: [[String: Any]], runs: Int) throws {
        let kinds = lines.compactMap { $0["kind"] as? String }
        XCTAssertEqual(kinds.first, "device")
        XCTAssertEqual(kinds.last, "end")
        XCTAssertEqual(kinds.filter { $0 == "device" }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == "end" }.count, 1)
        let end = try XCTUnwrap(lines.last)
        XCTAssertEqual(end["reason"] as? String, "done")
        XCTAssertEqual(end["runs"] as? Int, runs)
        let times = lines.compactMap { $0["t_us"] as? Int }
        XCTAssertEqual(times, times.sorted(), "t_us never goes back")
    }

    private func checkDevice(_ device: [String: Any]) throws {
        XCTAssertEqual(device["platform"] as? String, "ios")
        XCTAssertNotNil(device["phone"] as? String)
        XCTAssertEqual(device["phone"] as? String, device["soc"] as? String)
        XCTAssertNotNil(device["os_build"] as? String)
        XCTAssertEqual(device["schedule"] as? Int, 1)
        XCTAssertEqual(device["tier"] as? String, "U", "the simulator has no front camera")
        XCTAssertEqual(device["front_camera"] as? Bool, false)
        for key in ["low_ram", "camera_level", "egl_recordable"] {
            XCTAssertTrue(device[key] is NSNull, key)
        }
        let encoders = try XCTUnwrap(device["encoders"] as? [[String: Any]])
        XCTAssertFalse(encoders.isEmpty, "the H.264 entries of VTCopyVideoEncoderList")
        for encoder in encoders {
            XCTAssertNotNil(encoder["name"] as? String)
            XCTAssertNotNil(encoder["hw"] as? Bool)
        }
    }

    private func checkRun(_ lines: [[String: Any]], run: Int, schedule: ProbeSchedule) throws {
        let kinds = lines.compactMap { $0["kind"] as? String }
        XCTAssertEqual(kinds.filter { $0 == "run" }.count, 1, "run \(run)")
        XCTAssertEqual(kinds.filter { $0 == "run_end" }.count, 1, "run \(run)")
        XCTAssertEqual(kinds.first, "run", "run \(run)")
        XCTAssertEqual(kinds.last, "run_end", "run \(run)")
        let header = try XCTUnwrap(lines.first)
        XCTAssertEqual(header["rung"] as? Int, schedule.runs[run].rung.index)
        XCTAssertTrue(header["path"] is NSNull)
        XCTAssertTrue(header["hw"] is NSNull, "the simulator's encoder does not answer (-12900)")
        XCTAssertEqual(header["level"] as? String, "auto")
        let profile = try XCTUnwrap(header["profile"] as? String)
        let dropped = try XCTUnwrap(header["dropped"] as? [String])
        XCTAssertEqual(dropped, profile == "baseline" ? ["constrained_baseline"] : [])
        let params = try XCTUnwrap(lines.first { $0["kind"] as? String == "params" })
        XCTAssertEqual(params["source"] as? String, "format")
        let codec = try XCTUnwrap(params["codec"] as? String)
        XCTAssertTrue(codec.hasPrefix("avc1.42"), codec)
        XCTAssertLessThanOrEqual(Int(codec.suffix(2), radix: 16) ?? 99, 31, "level 3.1 at most")
        let outputs = lines.filter { $0["kind"] as? String == "out" }
        XCTAssertFalse(outputs.isEmpty)
        for output in outputs {
            XCTAssertEqual(output["param_sets"] as? Bool, false)
            XCTAssertTrue(output["sc3"] is NSNull)
            XCTAssertEqual(output["key"] as? Bool, output["flag_key"] as? Bool)
        }
        try checkSummaries(lines, run: run)
        let requests = kinds.filter { $0 == "kf_req" }.count
        let rates = lines.filter { $0["kind"] as? String == "rate" }.compactMap {
            $0["kbps"] as? Int
        }
        if schedule.runs[run].mode == .step {
            XCTAssertEqual(requests, 0)
        } else {
            XCTAssertEqual(rates, [])
        }
        XCTAssertEqual(Self.scheduleFindings(lines, run: run, schedule: schedule), [], "run \(run)")
    }

    /// The `run_end` summaries equal what the run's lines give (Z-059's computation), to the
    /// three decimals the log keeps: a median of two latencies in whole microseconds can
    /// end in half a microsecond.
    private func checkSummaries(_ lines: [[String: Any]], run: Int) throws {
        let records: [ProbeRecord] = lines.compactMap { line in
            let time = Int64(line["t_us"] as? Int ?? 0)
            let pts = Int64(line["pts_us"] as? Int ?? 0)
            switch line["kind"] as? String {
            case "in": return .input(time: time, pts: pts)
            case "out":
                return .output(
                    time: time, pts: pts, bytes: line["bytes"] as? Int ?? 0,
                    key: line["key"] as? Bool ?? false)
            case "kf_req":
                return .keyframeRequest(time: time, repeated: line["repeat"] as? Bool ?? true)
            default: return nil
            }
        }
        let summary = ProbeSummary(records)
        let end = try XCTUnwrap(lines.last)
        XCTAssertEqual(end["in"] as? Int, records.filter { $0.kind == .input }.count)
        XCTAssertEqual(end["out"] as? Int, records.filter { $0.kind == .output }.count)
        XCTAssertEqual(
            end["idr"] as? Int, end["idr_bare"] as? Int, "SPS and PPS stay out of buffers")
        XCTAssertTrue(end["error"] is NSNull, "run \(run): \(end["error"] ?? "")")
        let pairs: [(String, Double?)] = [
            ("delivered_kbps", summary.deliveredKbps), ("kf_latency_ms", summary.keyframeLatencyMs),
            ("kf_frames", summary.keyframeFrames), ("min_fps", summary.minFps.map(Double.init)),
        ]
        for (key, value) in pairs {
            let logged = end[key] as? Double
            XCTAssertEqual(logged == nil, value == nil, "run \(run) \(key)")
            if let logged, let value {
                XCTAssertEqual(logged, value, accuracy: 0.001, "run \(run) \(key)")
            }
        }
    }
}

/// The check of a run's keyframe requests and bitrate steps by the log's own times, and
/// the lines it reads, built in memory.
extension ZakadiSDKIntegrationTests {
    /// What a run's lines, in the order they were written, break of the run's keyframe
    /// requests and bitrate steps (Z-064's Spec, D120). `RunController` counts from the
    /// run's first IDR only once its output reaches the pipeline's queue, so only the `in`
    /// lines after the first key `out` line oblige anything, by their `pts_us` past that
    /// line's: one the keyframe delay or more past it comes after a `kf_req` line, and one
    /// that reaches a step's time comes after that step's `rate` line, the `rate` lines
    /// being a prefix of the steps. The first `in` line to reach a time stands for every
    /// later one.
    static func scheduleFindings(
        _ lines: [[String: Any]], run: Int, schedule: ProbeSchedule
    ) -> [String] {
        let entry = schedule.runs[run]
        let kinds = lines.map { $0["kind"] as? String }
        let rates = kinds.indices.filter { kinds[$0] == "rate" }
        let kbps = rates.compactMap { lines[$0]["kbps"] as? Int }
        let steps = entry.rateSteps.map(\.kbps)
        var findings: [String] = []
        if !steps.starts(with: kbps) {
            findings.append("the rate lines \(kbps) are not a prefix of \(steps)")
        }
        guard
            let key = kinds.indices.first(where: {
                kinds[$0] == "out" && lines[$0]["key"] as? Bool == true
            }),
            let origin = lines[key]["pts_us"] as? Int
        else { return findings }
        let inputs: [(index: Int, past: Int)] = kinds.indices.compactMap { index in
            guard index > key, kinds[index] == "in", let pts = lines[index]["pts_us"] as? Int
            else { return nil }
            return (index, pts - origin)
        }
        /// A finding unless the first `in` line `milliseconds` or more past the key `out`
        /// line, if there is one, comes after the line at `needed`.
        func check(_ milliseconds: Int, needs needed: Int?, _ missing: String) {
            guard let input = inputs.first(where: { $0.past >= milliseconds * 1_000 }) else {
                return
            }
            if let needed, needed < input.index { return }
            let time = lines[input.index]["t_us"] as? Int ?? 0
            let place = "the in line at t_us \(time), \(input.past) us past the first key out"
            findings.append("no \(missing) before \(place)")
        }
        if entry.keyframeRequests {
            check(schedule.keyframeDelayMs, needs: kinds.firstIndex(of: "kf_req"), "kf_req")
        }
        for (number, step) in entry.rateSteps.enumerated() {
            let stepLine = number < rates.count ? rates[number] : nil
            check(step.atMs, needs: stepLine, "rate \(step.kbps)")
        }
        return findings
    }

    /// A line as `parse` returns it, with the keys the schedule check reads.
    static func memoryLine(_ kind: String, _ time: Int, _ fields: [String: Any]) -> [String: Any] {
        fields.merging(["v": 1, "kind": kind, "t_us": time]) { field, _ in field }
    }

    /// The schedule check's findings over run `run` of schedule 1 shortened by 10, its lines
    /// built in memory and put in the order of their `t_us`, as the probe writes them: frames
    /// 0 to `last`, one every 50 ms, each with its `in` line 5 ms after its time and its `out`
    /// line, key for frame 0, `lag` after that, among the lines `with`.
    static func memoryFindings(
        run: Int, through last: Int, lag: Int = 10_000, with others: [[String: Any]] = []
    ) -> [String] {
        let frames = (0...last).flatMap { frame -> [[String: Any]] in
            let pts = frame * 50_000
            return [
                memoryLine("in", pts + 5_000, ["run": run, "pts_us": pts]),
                memoryLine(
                    "out", pts + 5_000 + lag, ["run": run, "pts_us": pts, "key": frame == 0]),
            ]
        }
        let lines = (frames + others).sorted {
            ($0["t_us"] as? Int ?? 0) < ($1["t_us"] as? Int ?? 0)
        }
        return scheduleFindings(lines, run: run, schedule: ProbeSchedule.one.shortened(by: 10))
    }
}
