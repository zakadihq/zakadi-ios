import Foundation
import XCTest
@_spi(Testing) import ZakadiSDK
@_spi(Testing) import ZakadiSDKTesting

/// Schedule 1, shortened, on the iOS simulator over the synthetic source (spec 09 9.11
/// item 6): the log it writes parses in full. `ci.yml` runs it in the `integration` job.
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
            XCTAssertEqual(rates, [200, 400])
        } else {
            XCTAssertGreaterThan(requests, 0, "run \(run)")
            XCTAssertEqual(rates, [])
        }
    }

    /// The `run_end` summaries equal what the run's lines give (Z-059's computation).
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
                XCTAssertEqual(logged, value, accuracy: 0.0005, "run \(run) \(key)")
            }
        }
    }
}
