import CoreMedia
import CoreVideo
import Foundation
import XCTest

@_spi(Testing) @testable import ZakadiSDK

/// Frames, sources and encoder runs the media tests share.
enum MediaFixtures {
    /// A 420v buffer whose luma is `luma(column)` on every row, chroma grey.
    static func frame(width: Int, height: Int, luma: (Int) -> UInt8) throws -> CVPixelBuffer {
        let pool = try FrameScaler.pool(width: width, height: height)
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let rows = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        let line = (0..<width).map(luma)
        for row in 0..<height {
            line.withUnsafeBytes { _ = memcpy(rows + row * stride, $0.baseAddress, width) }
        }
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 1))
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(frame, 1) * height / 2)
        return frame
    }

    /// A moving pattern, different for every `index`, so that P-frames carry data.
    static func movingFrame(
        _ index: Int, width: Int = 480, height: Int = 640
    ) throws -> CVPixelBuffer {
        try frame(width: width, height: height) { UInt8(truncatingIfNeeded: ($0 + index * 3) * 5) }
    }

    /// The luma at a pixel.
    static func luma(_ buffer: CVPixelBuffer, column: Int, row: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return base.load(fromByteOffset: row * stride + column, as: UInt8.self)
    }

    /// Frame `index` of a 30 fps source, exact.
    static func time(_ index: Int, fps: Int = 30) -> CMTime {
        CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
    }

    /// Settings at a rung of spec 01 1.5 that any H.264 encoder, software included, takes.
    static func settings(rung: Int) -> EncoderSettings {
        EncoderSettings(rung: Rung.exampleLadder[rung], preference: .any)
    }
}

/// Collects an encoder's outputs, which arrive on VideoToolbox's threads.
final class OutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [EncoderOutput] = []

    func append(_ output: EncoderOutput) {
        lock.withLock { outputs.append(output) }
    }

    var frames: [EncodedFrame] {
        lock.withLock {
            outputs.compactMap {
                if case .frame(let frame) = $0 { return frame }
                return nil
            }
        }
    }
}

/// A source the test drives: `push` delivers a frame on the pipeline's queue.
final class ManualFrameSource: FrameSource, @unchecked Sendable {
    var format: CaptureFormat?
    private var handler: ((CapturedFrame) -> Void)?

    func start(
        queue: DispatchQueue, handler: @escaping (CapturedFrame) -> Void
    ) throws(FrameSourceError) {
        self.handler = handler
        format = CaptureFormat(
            width: 480, height: 640, rotation: 0, fps: 30...30, exposureBias: nil, hostClock: true)
    }

    func stop() {
        handler = nil
    }

    /// Delivers frame `index` of a 30 fps source; call it on the pipeline's queue.
    func push(_ index: Int) throws {
        handler?(
            CapturedFrame(
                pixelBuffer: try MediaFixtures.movingFrame(index),
                presentationTime: MediaFixtures.time(index)))
    }
}
