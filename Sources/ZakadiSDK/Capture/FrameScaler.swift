import CoreImage
import CoreVideo
import VideoToolbox

/// A frame the scaler could not produce, with the Core Video or VideoToolbox status.
@_spi(Testing) public struct ScalerError: Error, Equatable {
    public var operation: String
    public var status: Int32
}

/// Scales captured frames to a rung's size (spec 07 7.29): capture stays at 480x640 and
/// rungs 3 and 4 (336x448, 288x384) scale into pooled 420v buffers, with
/// `VTPixelTransferSession` from iOS 16 and `CIContext` below. A source that is not 3:4 is
/// cropped about its centre first (spec 05 5.3).
@_spi(Testing) public final class FrameScaler {
    /// How the scaler draws.
    public enum Method: Sendable, Equatable {
        case pixelTransfer
        case coreImage
    }

    /// The method this OS gets: `VTPixelTransferSession` exists from iOS 16.
    public static var defaultMethod: Method {
        if #available(iOS 16, *) { return .pixelTransfer }
        return .coreImage
    }

    public let method: Method
    private var transfer: AnyObject?
    private lazy var context = CIContext(options: [.workingColorSpace: NSNull()])
    private var pools: [Int: CVPixelBufferPool] = [:]

    public init(method: Method = FrameScaler.defaultMethod) {
        self.method = method
    }

    /// `source` as a `width` x `height` 420v buffer from the pool of that size.
    public func scale(
        _ source: CVPixelBuffer, width: Int, height: Int
    ) throws(ScalerError) -> CVPixelBuffer {
        let destination = try buffer(width: width, height: height)
        if method == .pixelTransfer, #available(iOS 16, *) {
            try pixelTransfer().transfer(source, to: destination)
        } else {
            render(source, into: destination)
        }
        return destination
    }

    @available(iOS 16, *)
    private func pixelTransfer() throws(ScalerError) -> PixelTransfer {
        if let existing = transfer as? PixelTransfer { return existing }
        let created = try PixelTransfer()
        transfer = created
        return created
    }

    private func render(_ source: CVPixelBuffer, into destination: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: source)
        let crop = Self.centreCrop(
            width: Double(CVPixelBufferGetWidth(source)),
            height: Double(CVPixelBufferGetHeight(source)),
            aspect: Double(CVPixelBufferGetWidth(destination))
                / Double(CVPixelBufferGetHeight(destination)))
        let scale = Double(CVPixelBufferGetWidth(destination)) / crop.width
        let scaled = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(scaled, to: destination)
    }

    /// The largest rectangle of `aspect` (width over height) centred in the source.
    static func centreCrop(width: Double, height: Double, aspect: Double) -> CGRect {
        if width / height > aspect {
            let cropped = height * aspect
            return CGRect(x: (width - cropped) / 2, y: 0, width: cropped, height: height)
        }
        let cropped = width / aspect
        return CGRect(x: 0, y: (height - cropped) / 2, width: width, height: cropped)
    }

    private func buffer(width: Int, height: Int) throws(ScalerError) -> CVPixelBuffer {
        let key = width << 16 | height
        let pool: CVPixelBufferPool
        if let existing = pools[key] {
            pool = existing
        } else {
            pool = try Self.pool(width: width, height: height)
            pools[key] = pool
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw ScalerError(operation: "CVPixelBufferPoolCreatePixelBuffer", status: status)
        }
        return buffer
    }

    /// A pool of IOSurface-backed 420v buffers, which VideoToolbox takes without a copy.
    public static func pool(width: Int, height: Int) throws(ScalerError) -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: CaptureSettings.pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw ScalerError(operation: "CVPixelBufferPoolCreate", status: status)
        }
        return pool
    }
}

/// A `VTPixelTransferSession` in trim mode: the source keeps its aspect ratio and is
/// cropped about its centre to fill the destination.
@available(iOS 16, *)
private final class PixelTransfer {
    private let session: VTPixelTransferSession

    init() throws(ScalerError) {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: nil, pixelTransferSessionOut: &session)
        guard status == noErr, let session else {
            throw ScalerError(operation: "VTPixelTransferSessionCreate", status: status)
        }
        VTSessionSetProperty(
            session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
        self.session = session
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    func transfer(_ source: CVPixelBuffer, to destination: CVPixelBuffer) throws(ScalerError) {
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else {
            throw ScalerError(operation: "VTPixelTransferSessionTransferImage", status: status)
        }
    }
}
