/// One `in`, `out` or `kf_req` line of a run, the lines the summaries read.
@_spi(Testing) public struct ProbeRecord: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case input
        case output
        case keyframeRequest
    }

    public var kind: Kind
    /// `t_us` of the line.
    public var time: Int64
    /// `pts_us` of an `in` or `out` line.
    public var pts: Int64
    /// `bytes` of an `out` line.
    public var bytes: Int
    /// `key` of an `out` line.
    public var key: Bool
    /// `repeat` of a `kf_req` line.
    public var repeated: Bool

    public static func input(time: Int64, pts: Int64) -> ProbeRecord {
        ProbeRecord(kind: .input, time: time, pts: pts, bytes: 0, key: false, repeated: false)
    }

    public static func output(time: Int64, pts: Int64, bytes: Int, key: Bool) -> ProbeRecord {
        ProbeRecord(kind: .output, time: time, pts: pts, bytes: bytes, key: key, repeated: false)
    }

    public static func keyframeRequest(time: Int64, repeated: Bool) -> ProbeRecord {
        ProbeRecord(
            kind: .keyframeRequest, time: time, pts: 0, bytes: 0, key: false, repeated: repeated)
    }
}

/// The summaries of a `run_end` line, as Z-059 computes them from the run's lines
/// (Z-064's Spec); each nil where its lines give no value.
@_spi(Testing) public struct ProbeSummary: Sendable, Equatable {
    /// 8 times the bytes of the `out` lines from the first key one, over their `pts_us`
    /// span, in kbit/s.
    public var deliveredKbps: Double?
    /// The median `t_us` gap from a `kf_req` without `repeat` to the next key `out`.
    public var keyframeLatencyMs: Double?
    /// The median count of `in` lines after such a request up to the frame of that `out`.
    public var keyframeFrames: Double?
    /// The least count of `out` lines in a 1 s window of `pts_us` that opens on an `out`
    /// line at or after the first key one and ends by the last.
    public var minFps: Int?

    public init(
        deliveredKbps: Double?, keyframeLatencyMs: Double?, keyframeFrames: Double?, minFps: Int?
    ) {
        self.deliveredKbps = deliveredKbps
        self.keyframeLatencyMs = keyframeLatencyMs
        self.keyframeFrames = keyframeFrames
        self.minFps = minFps
    }

    /// The summaries of one run's records, in line order.
    public init(_ records: [ProbeRecord]) {
        let outputs = records.filter { $0.kind == .output }
        let delivered = Array(outputs.drop { !$0.key })
        self.init(
            deliveredKbps: Self.deliveredKbps(delivered),
            keyframeLatencyMs: nil, keyframeFrames: nil, minFps: Self.minFps(delivered))
        var latencies: [Double] = []
        var frames: [Double] = []
        for (index, request) in records.enumerated()
        where request.kind == .keyframeRequest && !request.repeated {
            let later = records[(index + 1)...]
            guard let found = later.firstIndex(where: { $0.kind == .output && $0.key }) else {
                continue
            }
            let answer = records[found]
            latencies.append(Double(answer.time - request.time) / 1000)
            let inputs = records[(index + 1)..<found].filter {
                $0.kind == .input && $0.pts <= answer.pts
            }
            frames.append(Double(inputs.count))
        }
        keyframeLatencyMs = Self.median(latencies)
        keyframeFrames = Self.median(frames)
    }

    static func deliveredKbps(_ outputs: [ProbeRecord]) -> Double? {
        guard let first = outputs.first, let last = outputs.last, last.pts > first.pts else {
            return nil
        }
        let bits = outputs.reduce(0) { $0 + $1.bytes } * 8
        return Double(bits) * 1000 / Double(last.pts - first.pts)
    }

    static func minFps(_ outputs: [ProbeRecord]) -> Int? {
        guard let last = outputs.last?.pts else { return nil }
        var least: Int?
        for (index, start) in outputs.enumerated() where start.pts + 1_000_000 <= last {
            let count = outputs[index...].prefix { $0.pts < start.pts + 1_000_000 }.count
            least = min(least ?? count, count)
        }
        return least
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
