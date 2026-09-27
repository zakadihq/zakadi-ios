import AVFoundation

/// A device tier (spec 07 7.26): unsupported, limited or standard.
@_spi(Testing) public enum DeviceTier: String, Sendable {
    case unsupported = "U"
    case limited = "L"
    case standard = "S"
}

/// The iOS checks of the capability probe in spec 07 7.3: a front camera and a VideoToolbox
/// session at 480x640. The audio self-test waits for 7.31.
@_spi(Testing) public struct CapabilityCheck: Sendable, Equatable {
    public var frontCamera: Bool
    /// A session at 480x640 with the settings of spec 07 7.30 was created and prepared.
    public var encoderSession: Bool
    /// Creating, preparing and invalidating that session, in milliseconds.
    public var configureMs: Double
    /// Unsupported without a front camera or the session, standard otherwise.
    public var tier: DeviceTier {
        frontCamera && encoderSession ? .standard : .unsupported
    }

    public init(frontCamera: Bool, encoderSession: Bool, configureMs: Double) {
        self.frontCamera = frontCamera
        self.encoderSession = encoderSession
        self.configureMs = configureMs
    }

    /// Runs both checks; the session check at rung 2 of spec 01 1.5 with `preference`.
    public static func run(preference: EncoderPreference) -> CapabilityCheck {
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        let start = HostClock.nowMicroseconds
        let encoder = try? VideoEncoder(
            settings: EncoderSettings(rung: Rung.exampleLadder[2], preference: preference)
        ) { _ in }
        encoder?.finish()
        let elapsed = Double(HostClock.nowMicroseconds - start) / 1000
        return CapabilityCheck(
            frontCamera: camera != nil, encoderSession: encoder != nil, configureMs: elapsed)
    }
}
