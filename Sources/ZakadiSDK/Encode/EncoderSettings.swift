import VideoToolbox

/// Which VideoToolbox H.264 encoders a session may use.
@_spi(Testing) public enum EncoderPreference: String, Sendable {
    /// Hardware only, as spec 07 7.30 asks from iOS 17.4
    /// (`RequireHardwareAcceleratedVideoEncoder`); below it VideoToolbox picks.
    case hardware
    /// Any encoder, software included: the simulator's, and a Mac's where it has no hardware
    /// H.264 encoder.
    case any
}

/// The H.264 profiles a session asks for, in order (spec 05 5.4, D5).
@_spi(Testing) public enum H264Profile: String, Sendable, CaseIterable {
    case constrainedBaseline = "constrained_baseline"
    case baseline

    /// The `ProfileLevel` value asked for, at the level the encoder picks: spec 05 5.4 allows
    /// 3.1 at most, and the SPS shows the level picked.
    public var profileLevel: CFString {
        switch self {
        case .constrainedBaseline: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        case .baseline: kVTProfileLevel_H264_Baseline_AutoLevel
        }
    }
}

/// What a session is created with: a rung's size, frame rate and bitrate, `ready.gop_ms`
/// and the encoder preference.
@_spi(Testing) public struct EncoderSettings: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var kbps: Int
    public var gopMs: Int
    public var preference: EncoderPreference

    public init(rung: Rung, gopMs: Int = 2000, preference: EncoderPreference = .hardware) {
        width = rung.width
        height = rung.height
        fps = rung.fps
        kbps = rung.videoKbps
        self.gopMs = gopMs
        self.preference = preference
    }

    /// `DataRateLimits` for `kbps` (spec 07 7.30): 1.5 times the average bitrate, as bytes
    /// over one second.
    public static func dataRateLimits(kbps: Int) -> [Int] {
        [kbps * 1000 / 8 * 3 / 2, 1]
    }
}

/// The encoder properties a session reports once created, each nil when VideoToolbox does
/// not answer: the `out_format` of the encoder log.
@_spi(Testing) public struct EncoderReadBack: Sendable, Equatable {
    public var profileLevel: String?
    public var averageBitRate: Int?
    public var dataRateLimits: [Double]?
    public var expectedFrameRate: Double?
    public var maxKeyFrameInterval: Int?
    public var maxKeyFrameIntervalDuration: Double?
    public var realTime: Bool?
    public var allowFrameReordering: Bool?

    public init() {}
}

/// What a session was asked for and what it took.
@_spi(Testing) public struct EncoderReport: Sendable, Equatable {
    public var settings: EncoderSettings
    /// Constrained Baseline, or Baseline when the session refused it.
    public var profile: H264Profile
    /// The profiles refused before `profile`, in the order asked.
    public var refused: [H264Profile]
    /// `EncoderID`, or nil when unreadable.
    public var encoderID: String?
    /// `UsingHardwareAcceleratedVideoEncoder` from iOS 17.4; nil below it and when the
    /// encoder does not answer.
    public var usingHardware: Bool?
    public var readBack: EncoderReadBack
}
