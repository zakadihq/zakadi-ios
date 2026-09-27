@_spi(Testing) import ZakadiSDK

/// A probe schedule (Z-064's Spec): the runs a probe makes, each on a new encoder while the
/// camera stays bound, as a rung change would.
@_spi(Testing) public struct ProbeSchedule: Sendable, Equatable {
    public enum Mode: String, Sendable {
        /// One rung's size, rate and bitrate throughout.
        case constant
        /// Bitrate steps at one size and rate.
        case step
    }

    /// A live bitrate request, a time after the run's first IDR.
    public struct RateStep: Sendable, Equatable {
        public var atMs: Int
        public var kbps: Int
    }

    public struct Run: Sendable, Equatable {
        public var mode: Mode
        public var rung: Rung
        /// From the run's first IDR.
        public var durationMs: Int
        /// A keyframe request `keyframeDelayMs` after every IDR that answered no request.
        public var keyframeRequests: Bool
        public var rateSteps: [RateStep]
    }

    /// The number the log's `device` line carries.
    public var number: Int
    public var runs: [Run]
    /// `gop_ms` of spec 01 1.5.
    public var gopMs: Int
    public var keyframeDelayMs: Int
    /// 1 as specified; a shortened schedule divides every duration and step time by it.
    public var divisor: Int

    /// Schedule 1: runs 0 to 4 constant at rungs 0 to 4 of spec 01 1.5, 20 s each and
    /// rung 2 for 60 s (spec 10 10.3), then run 5 stepping rung 2 from 400 to 200 kbps at
    /// 6 s and back at 12 s, 18 s long, without keyframe requests.
    public static let one: ProbeSchedule = {
        let ladder = Rung.exampleLadder
        let constant = ladder.map { rung in
            Run(
                mode: .constant, rung: rung, durationMs: rung.index == 2 ? 60_000 : 20_000,
                keyframeRequests: true, rateSteps: [])
        }
        let step = Run(
            mode: .step, rung: ladder[2], durationMs: 18_000, keyframeRequests: false,
            rateSteps: [RateStep(atMs: 6_000, kbps: 200), RateStep(atMs: 12_000, kbps: 400)])
        return ProbeSchedule(
            number: 1, runs: constant + [step], gopMs: 2_000, keyframeDelayMs: 1_000, divisor: 1)
    }()

    /// The same runs with every duration and step time divided by `divisor`; the GOP and
    /// the keyframe delay stay as they are.
    public func shortened(by divisor: Int) -> ProbeSchedule {
        var copy = self
        copy.divisor = self.divisor * divisor
        copy.runs = runs.map { run in
            var run = run
            run.durationMs /= divisor
            run.rateSteps = run.rateSteps.map { RateStep(atMs: $0.atMs / divisor, kbps: $0.kbps) }
            return run
        }
        return copy
    }
}

/// What a run of a schedule does next, from frame and IDR times alone (microseconds on
/// the frames' clock): the keyframe requests, the bitrate steps and the end.
@_spi(Testing) public struct RunController: Sendable {
    public enum Action: Sendable, Equatable {
        case requestKeyframe
        case setBitrate(Int)
        case end
    }

    public let run: ProbeSchedule.Run
    public let keyframeDelay: Int64
    /// The time of the run's first IDR.
    public private(set) var firstIDR: Int64?
    public private(set) var ended = false
    private var keyframeDue: Int64?
    private var outstanding = 0
    private var steps = 0

    public init(run: ProbeSchedule.Run, keyframeDelayMs: Int) {
        self.run = run
        keyframeDelay = Int64(keyframeDelayMs) * 1000
    }

    /// Before the frame at `time` goes on to the pacer: nothing until the first IDR, then
    /// the end once the duration has passed, else a due request and the steps reached.
    public mutating func frame(at time: Int64) -> [Action] {
        guard !ended, let first = firstIDR else { return [] }
        let elapsed = time - first
        if elapsed >= Int64(run.durationMs) * 1000 {
            ended = true
            return [.end]
        }
        var actions: [Action] = []
        if let due = keyframeDue, time >= due {
            keyframeDue = nil
            outstanding += 1
            actions.append(.requestKeyframe)
        }
        while steps < run.rateSteps.count, elapsed >= Int64(run.rateSteps[steps].atMs) * 1000 {
            actions.append(.setBitrate(run.rateSteps[steps].kbps))
            steps += 1
        }
        return actions
    }

    /// An output holding an IDR at `time`: it answers every request before it, and one
    /// that answers none schedules the next request.
    public mutating func idr(at time: Int64) {
        if firstIDR == nil { firstIDR = time }
        if outstanding > 0 {
            outstanding = 0
        } else if run.keyframeRequests {
            keyframeDue = time + keyframeDelay
        }
    }
}
