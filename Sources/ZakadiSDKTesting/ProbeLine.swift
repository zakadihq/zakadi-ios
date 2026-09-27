import Foundation
@_spi(Testing) import ZakadiSDK

/// What a `run` line says about its run.
@_spi(Testing) public struct RunDescription: Sendable, Equatable {
    public var index: Int
    public var run: ProbeSchedule.Run
    public var gopMs: Int
    public var report: EncoderReport
    public var camera: CaptureFormat?
    /// The first submitted frame's time on the `t_us` clock; nil off the host clock.
    public var firstFrame: Int64?
    public var thermal: String
}

/// The counters of a `tick` line.
@_spi(Testing) public struct TickCounts: Sendable, Equatable {
    public var captured = 0
    public var submitted = 0
    public var encoded = 0
    public var preEncodeDrops = 0
    public var encoderQueue = 0
    public var encodedKbps = 0.0
    public var thermal = "nominal"
    public var cpuMs = 0.0
    public var encoderDropped = 0

    public init() {}
}

/// The counts and summaries of a `run_end` line.
@_spi(Testing) public struct RunTotals: Sendable, Equatable {
    public var inputs = 0
    public var outputs = 0
    public var idr = 0
    /// IDR buffers without SPS and PPS inside: every IDR on iOS, whose SPS and PPS stay in
    /// the format description.
    public var bareIDR = 0
    public var summary = ProbeSummary([])
    public var error: String?

    public init() {}
}

/// Why a probe ended.
@_spi(Testing) public enum EndReason: String, Sendable {
    case done
    case unsupportedDevice = "unsupported_device"
    case error
}

/// Log format 1 of the encoder probe, as Z-064's Spec fixes it (D105), with the values iOS
/// reads: one ASCII JSON object per line, keys in the order listed, `null` where the
/// platform cannot read a value. Every line opens with `v`, `kind` and `t_us`.
@_spi(Testing) public enum ProbeLine {
    public static let version = 1

    public static func device(_ facts: DeviceFacts, schedule: Int, args: JSONValue) -> JSONValue {
        let machine = JSONValue.of(facts.machine)
        return .object(
            header("device", 0)
                + JSONValue.fieldList([
                    "wall_ms": .int(facts.wallMs), "platform": "ios", "phone": machine,
                    "soc": machine, "os": .string(facts.osVersion),
                    "os_build": .of(facts.osBuild), "schedule": .of(schedule), "args": args,
                    "tier": .string(facts.check.tier.rawValue), "low_ram": nil,
                    "mem_mb": .of(facts.memoryMb), "camera_level": nil, "egl_recordable": nil,
                    "front_camera": .bool(facts.check.frontCamera),
                    "configure_ms": .double(facts.check.configureMs),
                    "encoders": .array(facts.encoders.map(encoder)),
                    "thermal": .string(facts.thermal), "battery_pct": .of(facts.battery.percent),
                    "charging": .of(facts.battery.charging),
                ]))
    }

    static func encoder(_ info: EncoderInfo) -> JSONValue {
        .fields([
            "name": .string(info.encoderID), "hw": .bool(info.hardwareAccelerated),
            "vendor": nil, "alias": nil, "cbr": .of(info.constantBitRate),
            "cb": .of(info.constrainedBaseline), "max_level": .of(info.maxBaselineLevel),
            "rungs": nil, "kbps_range": nil, "achievable_fps": nil,
        ])
    }

    public static func run(_ run: RunDescription, at time: Int64) -> JSONValue {
        let report = run.report
        return .object(
            header("run", time)
                + JSONValue.fieldList([
                    "run": .of(run.index), "mode": .string(run.run.mode.rawValue),
                    "rung": .of(run.run.rung.index), "w": .of(report.settings.width),
                    "h": .of(report.settings.height), "fps": .of(report.settings.fps),
                    "kbps": .of(report.settings.kbps), "gop_ms": .of(run.gopMs), "path": nil,
                    "encoder": .of(report.encoderID), "hw": .of(report.usingHardware),
                    "profile": .string(report.profile.rawValue), "level": "auto",
                    "bitrate_mode": "abr",
                    "dropped": .array(report.refused.map { .string($0.rawValue) }),
                    "out_format": outFormat(report.readBack), "camera": camera(run.camera),
                    "t0_us": .of(run.firstFrame), "thermal": .string(run.thermal),
                ]))
    }

    static func outFormat(_ readBack: EncoderReadBack) -> JSONValue {
        .fields([
            "profile_level": .of(readBack.profileLevel),
            "average_bit_rate": .of(readBack.averageBitRate),
            "data_rate_limits": readBack.dataRateLimits.map { .array($0.map(JSONValue.double)) }
                ?? .null,
            "expected_frame_rate": .of(readBack.expectedFrameRate),
            "max_key_frame_interval": .of(readBack.maxKeyFrameInterval),
            "max_key_frame_interval_duration": .of(readBack.maxKeyFrameIntervalDuration),
            "real_time": .of(readBack.realTime),
            "allow_frame_reordering": .of(readBack.allowFrameReordering),
        ])
    }

    static func camera(_ format: CaptureFormat?) -> JSONValue {
        guard let format else { return nil }
        return .fields([
            "w": .of(format.width), "h": .of(format.height), "rotation": .of(format.rotation),
            "fps_min": .double(format.minFps), "fps_max": .double(format.maxFps),
            "ev": .of(format.exposureBias.map { Double($0) }),
            "clock": .string(format.hostClock ? "host" : "other"),
        ])
    }

    public static func params(run: Int, sets: ParameterSets, at time: Int64) -> JSONValue {
        .object(
            header("params", time)
                + JSONValue.fieldList([
                    "run": .of(run), "source": "format", "sps": .string(hex(sets.sps)),
                    "pps": .string(hex(sets.pps)),
                    "codec": .of(SequenceParameterSet(sets.sps)?.codec),
                ]))
    }

    public static func input(run: Int, pts: Int64, at time: Int64) -> JSONValue {
        .object(header("in", time) + JSONValue.fieldList(["run": .of(run), "pts_us": .of(pts)]))
    }

    public static func output(
        run: Int, pts: Int64, frame: EncodedFrame, at time: Int64
    ) -> JSONValue {
        .object(
            header("out", time)
                + JSONValue.fieldList([
                    "run": .of(run), "pts_us": .of(pts), "bytes": .of(frame.encoderBytes),
                    "key": .bool(frame.nalTypes.contains(5)), "flag_key": .bool(frame.isIDR),
                    "param_sets": .bool(frame.nalTypes.contains(7) && frame.nalTypes.contains(8)),
                    "sc3": nil, "nal": .array(frame.nalTypes.map { .int(Int64($0)) }),
                ]))
    }

    /// A `kf_req` line; `repeat` is false, since VideoToolbox requests are never repeated
    /// (spec 07 7.30).
    public static func keyframeRequest(run: Int, number: Int, at time: Int64) -> JSONValue {
        .object(
            header("kf_req", time)
                + JSONValue.fieldList(["run": .of(run), "n": .of(number), "repeat": false]))
    }

    public static func rate(run: Int, kbps: Int, at time: Int64) -> JSONValue {
        .object(header("rate", time) + JSONValue.fieldList(["run": .of(run), "kbps": .of(kbps)]))
    }

    public static func tick(run: Int, counts: TickCounts, at time: Int64) -> JSONValue {
        .object(
            header("tick", time)
                + JSONValue.fieldList([
                    "run": .of(run), "captured": .of(counts.captured),
                    "submitted": .of(counts.submitted), "encoded": .of(counts.encoded),
                    "pre_encode_drops": .of(counts.preEncodeDrops),
                    "enc_queue": .of(counts.encoderQueue),
                    "encoded_kbps": .double(counts.encodedKbps), "thermal": .string(counts.thermal),
                    "cpu_ms": .double(counts.cpuMs), "enc_dropped": .of(counts.encoderDropped),
                ]))
    }

    public static func runEnd(run: Int, totals: RunTotals, at time: Int64) -> JSONValue {
        let summary = totals.summary
        return .object(
            header("run_end", time)
                + JSONValue.fieldList([
                    "run": .of(run), "in": .of(totals.inputs), "out": .of(totals.outputs),
                    "idr": .of(totals.idr), "idr_bare": .of(totals.bareIDR),
                    "delivered_kbps": .of(summary.deliveredKbps),
                    "kf_latency_ms": .of(summary.keyframeLatencyMs),
                    "kf_frames": .of(summary.keyframeFrames), "min_fps": .of(summary.minFps),
                    "error": .of(totals.error),
                ]))
    }

    public static func end(
        runs: Int, reason: EndReason, thermal: String, battery: Battery, at time: Int64
    ) -> JSONValue {
        .object(
            header("end", time)
                + JSONValue.fieldList([
                    "runs": .of(runs), "reason": .string(reason.rawValue),
                    "thermal": .string(thermal), "battery_pct": .of(battery.percent),
                ]))
    }

    /// Lowercase hex, two digits a byte.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func header(_ kind: String, _ time: Int64) -> [JSONField] {
        [
            JSONField("v", .of(version)), JSONField("kind", .string(kind)),
            JSONField("t_us", .int(time)),
        ]
    }
}

extension JSONValue {
    static func fieldList(_ pairs: KeyValuePairs<String, JSONValue>) -> [JSONField] {
        pairs.map { JSONField($0.key, $0.value) }
    }
}
