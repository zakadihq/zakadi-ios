import Dispatch
import Foundation
import XCTest
@_spi(Testing) import ZakadiSDK
@_spi(Testing) import ZakadiSDKTesting

/// A log read back and checked against format 1 (Z-064's Spec, D120): ASCII, one JSON object
/// per line ending in a newline, each opening with `v` 1, `kind` and `t_us`, then the keys of
/// its kind in order.
struct ProbeLog {
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

    let lines: [[String: Any]]

    init(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n"), "every line ends in a newline")
        XCTAssertTrue(text.unicodeScalars.allSatisfy(\.isASCII), "ASCII only")
        lines = try text.split(separator: "\n").map { try Self.parse(String($0)) }
    }

    /// The lines of `kind`, in order.
    func lines(_ kind: String) -> [[String: Any]] {
        lines.filter { $0["kind"] as? String == kind }
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
                var end = index + 1
                while end < characters.count, characters[end] != "\"" {
                    end += characters[end] == "\\" ? 2 : 1
                }
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
}

/// A camera stand-in for the simulator, which has none: the synthetic source's frames under
/// the format a camera settles on once started (spec 07 7.29).
final class StubCamera: FrameSource, @unchecked Sendable {
    private let frames = SyntheticFrameSource()
    private let settled: CaptureFormat
    private(set) var format: CaptureFormat?

    init(_ format: CaptureFormat) {
        settled = format
    }

    func start(
        queue: DispatchQueue, handler: @escaping (CapturedFrame) -> Void
    ) throws(FrameSourceError) {
        try frames.start(queue: queue, handler: handler)
        format = settled
    }

    func stop() {
        frames.stop()
    }
}
