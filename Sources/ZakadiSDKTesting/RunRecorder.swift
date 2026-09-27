import Foundation
@_spi(Testing) import ZakadiSDK

/// One run of a probe while it goes, on the pipeline's queue: what schedule 1 does next,
/// the records its summaries are computed from and the counters of its `tick` lines.
final class RunRecorder: @unchecked Sendable {
    let index: Int
    var controller: RunController
    var report: EncoderReport?
    /// The first submitted frame's time on the frame clock, in microseconds: the origin of
    /// the run's `pts_us`.
    var origin: Int64?
    var records: [ProbeRecord] = []
    var totals = RunTotals()
    var error: String?
    var ending = false
    /// Frames and output bits since the last `tick`.
    var window = TickCounts()
    var windowBits = 0
    var preEncodeDrops = 0
    var encoderDropped = 0
    var submitted = 0
    var returned = 0
    var requests = 0
    var cpuMark = RunRecorder.cpuTime()

    init(index: Int, controller: RunController) {
        self.index = index
        self.controller = controller
    }

    /// Records a submitted frame; returns its `pts_us`.
    func input(_ time: Int64, pts: Int64) -> Int64 {
        let relative = pts - (origin ?? pts)
        window.submitted += 1
        submitted += 1
        totals.inputs += 1
        records.append(.input(time: time, pts: relative))
        return relative
    }

    /// Records an output; returns its `pts_us`.
    func output(_ time: Int64, pts: Int64, frame: EncodedFrame) -> Int64 {
        let relative = pts - (origin ?? pts)
        let key = frame.nalTypes.contains(5)
        window.encoded += 1
        windowBits += frame.annexB.count * 8
        returned += 1
        totals.outputs += 1
        if key {
            totals.idr += 1
            if !(frame.nalTypes.contains(7) && frame.nalTypes.contains(8)) { totals.bareIDR += 1 }
        }
        records.append(.output(time: time, pts: relative, bytes: frame.encoderBytes, key: key))
        return relative
    }

    /// The counts of a `tick` line, which starts the next window.
    func tick() -> TickCounts {
        var counts = window
        counts.preEncodeDrops = preEncodeDrops
        counts.encoderQueue = submitted - returned - encoderDropped
        counts.encodedKbps = Double(windowBits) / 1000
        counts.thermal = DeviceFacts.thermalState()
        let cpu = Self.cpuTime()
        counts.cpuMs = Double(cpu - cpuMark) / 1_000_000
        counts.encoderDropped = encoderDropped
        cpuMark = cpu
        window = TickCounts()
        windowBits = 0
        return counts
    }

    /// The totals of the `run_end` line.
    func finish() -> RunTotals {
        totals.summary = ProbeSummary(records)
        totals.error = error
        return totals
    }

    /// Process CPU time in nanoseconds.
    static func cpuTime() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    }
}
