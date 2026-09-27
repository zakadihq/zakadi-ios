import CoreMedia
import CoreVideo
import Dispatch

/// One frame a source delivered: a 420v pixel buffer, already upright and unmirrored, and
/// its presentation time on the source's clock.
@_spi(Testing) public struct CapturedFrame {
    public var pixelBuffer: CVPixelBuffer
    public var presentationTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
    }
}

/// What a source settled on once started (spec 07 7.29): the size of the frames it
/// delivers, the clockwise rotation it applied to make them upright, its frame rate range,
/// the exposure bias it applied and whether its clock reads the host time.
@_spi(Testing) public struct CaptureFormat: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Degrees, clockwise: `config.video.rotation` of spec 01 1.4.
    public var rotation: Int
    public var minFps: Double
    public var maxFps: Double
    /// EV, or nil where the source applies none.
    public var exposureBias: Float?
    /// The frame times are on the host time clock (spec 07 7.5).
    public var hostClock: Bool

    public init(
        width: Int, height: Int, rotation: Int, fps: ClosedRange<Double>, exposureBias: Float?,
        hostClock: Bool
    ) {
        self.width = width
        self.height = height
        self.rotation = rotation
        minFps = fps.lowerBound
        maxFps = fps.upperBound
        self.exposureBias = exposureBias
        self.hostClock = hostClock
    }
}

/// Why a source did not start.
@_spi(Testing) public enum FrameSourceError: Error, Equatable {
    /// No front camera: the device is unsupported (spec 07 7.3).
    case unavailable
    /// The host has not been granted the camera.
    case notAuthorized
    /// The capture session refused its configuration.
    case configuration(String)
}

/// The camera seam of spec 07 7.15: the capture pipeline takes its frames from any source,
/// the front camera on a device and a file or a synthetic source where there is none.
@_spi(Testing) public protocol FrameSource: AnyObject {
    /// What the source settled on; nil until it has started.
    var format: CaptureFormat? { get }

    /// Starts delivering frames to `handler` on `queue`, one call per frame.
    func start(queue: DispatchQueue, handler: @escaping (CapturedFrame) -> Void)
        throws(FrameSourceError)

    /// Stops delivering frames.
    func stop()
}
