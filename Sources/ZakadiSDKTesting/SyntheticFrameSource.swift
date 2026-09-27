import CoreMedia
import CoreVideo
import Dispatch
import Foundation
@_spi(Testing) import ZakadiSDK

/// A frame source for the simulator and tests, which have no camera (spec 07 7.15, 7.38):
/// upright 420v frames of moving stripes at `fps`, in real time, stamped on the host
/// clock.
@_spi(Testing) public final class SyntheticFrameSource: FrameSource, @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public private(set) var format: CaptureFormat?
    private var timer: DispatchSourceTimer?
    private var handler: ((CapturedFrame) -> Void)?
    private var pool: CVPixelBufferPool?
    private var index = 0
    private let ramp: [UInt8]

    public init(width: Int = 480, height: Int = 640, fps: Int = 30) {
        self.width = width
        self.height = height
        self.fps = fps
        ramp = (0..<(width + 2 * height)).map {
            UInt8(truncatingIfNeeded: ($0 / 12 % 2) * 96 + $0 % 128)
        }
    }

    public func start(
        queue: DispatchQueue, handler: @escaping (CapturedFrame) -> Void
    ) throws(FrameSourceError) {
        do throws(ScalerError) {
            pool = try FrameScaler.pool(width: width, height: height)
        } catch {
            throw .configuration(error.operation)
        }
        self.handler = handler
        format = CaptureFormat(
            width: width, height: height, rotation: 0, fps: Double(fps)...Double(fps),
            exposureBias: nil, hostClock: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps),
            leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.deliver() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        handler = nil
    }

    private func deliver() {
        guard let pool, let handler else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
            let buffer
        else { return }
        draw(into: buffer, shift: index * 2 % (2 * height))
        index += 1
        handler(CapturedFrame(pixelBuffer: buffer, presentationTime: HostClock.now))
    }

    /// Diagonal stripes over a gradient, moved `shift` pixels; grey chroma.
    private func draw(into buffer: CVPixelBuffer, shift: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
            let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        ramp.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<height {
                let offset = (row + shift) % (2 * height)
                memcpy(luma + row * lumaStride, base + offset, width)
            }
        }
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        memset(chroma, 128, chromaStride * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }
}
