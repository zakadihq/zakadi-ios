import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A VideoToolbox call or property that failed, with its status.
@_spi(Testing) public struct EncoderError: Error, Equatable {
    /// The function or property key.
    public var operation: String
    public var status: OSStatus
}

/// What a session reports for a frame it was given.
@_spi(Testing) public enum EncoderOutput: Sendable {
    case frame(EncodedFrame)
    /// The encoder dropped the frame at this presentation time (`frameDropped`).
    case dropped(CMTime)
    /// The output callback carried an error status for the frame at this time.
    case failed(CMTime, OSStatus)
}

/// The H.264 encoder of spec 07 7.30 without the sender, the boost and `BitrateGovernor`:
/// one `VTCompressionSession` at one size that asks for Constrained Baseline and takes
/// Baseline where it is refused (spec 05 5.4, D5). A size change is a new encoder.
@_spi(Testing) public final class VideoEncoder: @unchecked Sendable {
    public let report: EncoderReport
    private let session: VTCompressionSession
    private let output: @Sendable (EncoderOutput) -> Void
    private var finished = false

    /// Creates and prepares a session; `output` gets every frame's result, on any thread.
    public init(
        settings: EncoderSettings, output: @escaping @Sendable (EncoderOutput) -> Void
    ) throws(EncoderError) {
        let session = try Self.makeSession(settings)
        let profile: (profile: H264Profile, refused: [H264Profile])
        do throws(EncoderError) {
            profile = try Self.configure(session, settings)
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
        self.session = session
        self.output = output
        report = EncoderReport(
            settings: settings, profile: profile.profile, refused: profile.refused,
            encoderID: Self.property(session, kVTCompressionPropertyKey_EncoderID) as? String,
            usingHardware: Self.usingHardware(session), readBack: Self.readBack(session))
    }

    deinit {
        if !finished { VTCompressionSessionInvalidate(session) }
    }

    /// Submits one frame; `forceKeyFrame` asks for an IDR on this very frame
    /// (`kVTEncodeFrameOptionKey_ForceKeyFrame`, spec 05 5.4).
    public func encode(
        _ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyFrame: Bool
    ) -> OSStatus {
        let properties =
            forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let output = output
        return VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { status, flags, sampleBuffer in
            guard status == noErr else { return output(.failed(presentationTime, status)) }
            let dropped = flags.contains(.frameDropped)
            let frame = dropped ? nil : sampleBuffer.flatMap(EncodedFrame.init)
            output(frame.map(EncoderOutput.frame) ?? .dropped(presentationTime))
        }
    }

    /// A new bitrate between frames (spec 05 5.4, 07 7.30).
    public func setBitrate(kbps: Int) throws(EncoderError) {
        try Self.setBitrate(session, kbps: kbps)
    }

    /// Emits every pending frame to `output`, then invalidates the session.
    public func finish() {
        guard !finished else { return }
        finished = true
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// The encoder properties as the session reports them now.
    public func readBack() -> EncoderReadBack {
        Self.readBack(session)
    }

    /// Asks for each profile of `H264Profile` in order and returns the first the session
    /// takes, with those refused before it; throws the last refusal when none is taken.
    static func applyProfile(
        _ set: (CFString) -> OSStatus
    ) throws(EncoderError) -> (profile: H264Profile, refused: [H264Profile]) {
        var refused: [H264Profile] = []
        var status = noErr
        for profile in H264Profile.allCases {
            status = set(profile.profileLevel)
            if status == noErr { return (profile, refused) }
            refused.append(profile)
        }
        throw EncoderError(
            operation: kVTCompressionPropertyKey_ProfileLevel as String, status: status)
    }

    /// `AverageBitRate` and 1.5 times `DataRateLimits` (spec 07 7.30).
    static func setBitrate(_ session: VTCompressionSession, kbps: Int) throws(EncoderError) {
        try set(session, kVTCompressionPropertyKey_AverageBitRate, (kbps * 1000) as CFNumber)
        try set(
            session, kVTCompressionPropertyKey_DataRateLimits,
            EncoderSettings.dataRateLimits(kbps: kbps) as CFArray)
    }

    /// `UsingHardwareAcceleratedVideoEncoder`, which exists from iOS 17.4; nil below it and
    /// when the encoder does not answer.
    static func usingHardware(_ session: VTCompressionSession) -> Bool? {
        guard #available(iOS 17.4, *) else { return nil }
        return property(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
            as? Bool
    }

    /// A property's value, or nil when the session does not answer.
    static func property(_ session: VTSession, _ key: CFString) -> AnyObject? {
        var value: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value)
        return status == noErr ? value?.takeRetainedValue() : nil
    }
}

extension VideoEncoder {
    private static func makeSession(
        _ settings: EncoderSettings
    ) throws(EncoderError) -> VTCompressionSession {
        var specification: [CFString: Any] = [:]
        if settings.preference == .hardware, #available(iOS 17.4, *) {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] =
                true
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: CaptureSettings.pixelFormat,
            kCVPixelBufferWidthKey: settings.width,
            kCVPixelBufferHeightKey: settings.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.width), height: Int32(settings.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw EncoderError(operation: "VTCompressionSessionCreate", status: status)
        }
        return session
    }

    /// The properties of spec 07 7.30, in its order, then `PrepareToEncodeFrames`.
    private static func configure(
        _ session: VTCompressionSession, _ settings: EncoderSettings
    ) throws(EncoderError) -> (profile: H264Profile, refused: [H264Profile]) {
        try set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        let profile = try applyProfile {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: $0)
        }
        try set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(session, kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        try set(
            session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
            (settings.fps * settings.gopMs / 1000) as CFNumber)
        try set(
            session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            (Double(settings.gopMs) / 1000) as CFNumber)
        try setBitrate(session, kbps: settings.kbps)
        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else {
            throw EncoderError(
                operation: "VTCompressionSessionPrepareToEncodeFrames", status: status)
        }
        return profile
    }

    private static func set(
        _ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef
    ) throws(EncoderError) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw EncoderError(operation: key as String, status: status) }
    }

    private static func readBack(_ session: VTCompressionSession) -> EncoderReadBack {
        func number(_ key: CFString) -> NSNumber? {
            property(session, key) as? NSNumber
        }
        var readBack = EncoderReadBack()
        readBack.profileLevel = property(session, kVTCompressionPropertyKey_ProfileLevel) as? String
        readBack.averageBitRate = number(kVTCompressionPropertyKey_AverageBitRate)?.intValue
        readBack.dataRateLimits =
            (property(session, kVTCompressionPropertyKey_DataRateLimits)
            as? [NSNumber])?.map(\.doubleValue)
        readBack.expectedFrameRate =
            number(kVTCompressionPropertyKey_ExpectedFrameRate)?
            .doubleValue
        readBack.maxKeyFrameInterval =
            number(kVTCompressionPropertyKey_MaxKeyFrameInterval)?
            .intValue
        readBack.maxKeyFrameIntervalDuration =
            number(
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration)?.doubleValue
        readBack.realTime = property(session, kVTCompressionPropertyKey_RealTime) as? Bool
        readBack.allowFrameReordering =
            property(session, kVTCompressionPropertyKey_AllowFrameReordering) as? Bool
        return readBack
    }
}
