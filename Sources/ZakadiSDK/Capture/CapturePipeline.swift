import CoreMedia
import CoreVideo
import Dispatch

/// Why a captured frame did not reach the encoder: a pre-encode drop (spec 07 7.7).
@_spi(Testing) public enum DropReason: String, Sendable {
    /// Between encoders, as around a size change (spec 07 7.18).
    case noEncoder = "no_encoder"
    case pacing
    case decimation
    case scaling
}

/// What the pipeline reports to its listener, in order, on its queue: the events the
/// encoder log of phase 0 measurement 6 is written from.
@_spi(Testing) public enum PipelineEvent: Sendable {
    /// A frame arrived from the source, before pacing.
    case captured(CMTime)
    case dropped(CMTime, DropReason)
    /// A frame went to the encoder.
    case submitted(CMTime)
    /// VideoToolbox refused a frame, or failed it in the output callback.
    case encodeFailed(CMTime, Int32)
    /// VideoToolbox dropped a frame it was given.
    case encoderDropped(CMTime)
    case encoderStarted(EncoderReport)
    /// The encoder's last frame has been reported.
    case encoderStopped
    /// A new encoder after a size change could not be created.
    case encoderFailed(EncoderError)
    /// The SPS and PPS of the running encoder, first seen or changed; before the output
    /// that carries them.
    case parameterSets(ParameterSets)
    case output(EncodedFrame)
    case keyframeRequested
    case bitrateRequested(Int)
}

/// The capture pipeline of spec 07 7.29 up to the encoder: frames from a `FrameSource`,
/// the pacer of 7.18, the scaler, and the VideoToolbox encoder of 7.30.
///
/// Every method runs on `queue`, where the source delivers frames and the listener is
/// called, each event with the host time in microseconds.
@_spi(Testing) public final class CapturePipeline: @unchecked Sendable {
    public let queue = DispatchQueue(label: "dev.zakadi.sdk.capture")
    public let source: any FrameSource
    /// `device_quirks.max_fps`: caps the camera and every rung's rate.
    public let maxFps: Int
    private let scaler: FrameScaler
    private let listener: (PipelineEvent, Int64) -> Void
    private var encoder: VideoEncoder?
    private var pacer: Pacer
    private var keyframePending = false
    private var parameterSets: ParameterSets?

    public init(
        source: any FrameSource, maxFps: Int = 30,
        scaling: FrameScaler.Method = FrameScaler.defaultMethod,
        listener: @escaping (PipelineEvent, Int64) -> Void
    ) {
        self.source = source
        self.maxFps = maxFps
        scaler = FrameScaler(method: scaling)
        self.listener = listener
        pacer = Pacer(fps: maxFps)
    }

    /// Starts the source; frames are dropped until an encoder runs.
    public func startCapture() throws(FrameSourceError) {
        dispatchPrecondition(condition: .onQueue(queue))
        try source.start(queue: queue) { [weak self] frame in self?.handle(frame) }
    }

    public func stopCapture() {
        dispatchPrecondition(condition: .onQueue(queue))
        source.stop()
    }

    /// Creates an encoder when none runs; its first frame is an IDR.
    public func startEncoder(_ settings: EncoderSettings) throws(EncoderError) {
        dispatchPrecondition(condition: .onQueue(queue))
        precondition(encoder == nil, "stop the running encoder first")
        let encoder = try VideoEncoder(settings: settings) { [weak self] output in
            guard let self else { return }
            queue.async { self.handle(output) }
        }
        self.encoder = encoder
        pacer = Pacer(fps: min(settings.fps, maxFps), decimation: pacer.decimation)
        keyframePending = false
        parameterSets = nil
        emit(.encoderStarted(encoder.report))
    }

    /// Reports the running encoder's pending frames and ends it; `encoderStopped` follows
    /// its last output.
    public func stopEncoder() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let encoder else { return }
        self.encoder = nil
        encoder.finish()
        queue.async { [self] in emit(.encoderStopped) }
    }

    /// Moves to a rung (spec 07 7.18, 7.30): a new size stops the encoder and starts one at
    /// the new size after its last output, the frames in between dropped; the same size
    /// keeps the encoder with the new rate and bitrate.
    public func changeRung(_ settings: EncoderSettings) throws(EncoderError) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let current = encoder?.report.settings else { return try startEncoder(settings) }
        guard current.width == settings.width, current.height == settings.height else {
            stopEncoder()
            queue.async { [self] in
                do throws(EncoderError) {
                    try startEncoder(settings)
                } catch {
                    emit(.encoderFailed(error))
                }
            }
            return
        }
        pacer.setFps(min(settings.fps, maxFps))
        try setBitrate(kbps: settings.kbps)
    }

    /// An IDR on the next frame submitted (spec 05 5.4).
    public func requestKeyframe() {
        dispatchPrecondition(condition: .onQueue(queue))
        keyframePending = true
        emit(.keyframeRequested)
    }

    public func setBitrate(kbps: Int) throws(EncoderError) {
        dispatchPrecondition(condition: .onQueue(queue))
        emit(.bitrateRequested(kbps))
        try encoder?.setBitrate(kbps: kbps)
    }

    /// Decimation 0, 1 or 2 (spec 05 5.6, 07 7.18).
    public func setDecimation(_ level: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        pacer.setDecimation(level)
    }

    private func handle(_ frame: CapturedFrame) {
        let time = frame.presentationTime
        emit(.captured(time))
        guard let encoder else { return emit(.dropped(time, .noEncoder)) }
        switch pacer.decide(time) {
        case .keep: break
        case .pacing: return emit(.dropped(time, .pacing))
        case .decimation: return emit(.dropped(time, .decimation))
        }
        let settings = encoder.report.settings
        var pixelBuffer = frame.pixelBuffer
        let resized =
            CVPixelBufferGetWidth(pixelBuffer) != settings.width
            || CVPixelBufferGetHeight(pixelBuffer) != settings.height
        if resized {
            guard
                let scaled = try? scaler.scale(
                    pixelBuffer, width: settings.width, height: settings.height)
            else { return emit(.dropped(time, .scaling)) }
            pixelBuffer = scaled
        }
        let forceKeyFrame = keyframePending
        keyframePending = false
        let status = encoder.encode(
            pixelBuffer, presentationTime: time, forceKeyFrame: forceKeyFrame)
        emit(status == noErr ? .submitted(time) : .encodeFailed(time, status))
    }

    private func handle(_ output: EncoderOutput) {
        switch output {
        case .frame(let frame):
            if let sets = frame.parameterSets, sets != parameterSets {
                parameterSets = sets
                emit(.parameterSets(sets))
            }
            emit(.output(frame))
        case .dropped(let time):
            emit(.encoderDropped(time))
        case .failed(let time, let status):
            emit(.encodeFailed(time, status))
        }
    }

    private func emit(_ event: PipelineEvent) {
        listener(event, HostClock.nowMicroseconds)
    }
}
