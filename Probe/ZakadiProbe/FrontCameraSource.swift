import AVFoundation
import Dispatch
@_spi(Testing) import ZakadiSDK

/// Z-068's camera source behind the capability check of spec 07 7.3, which comes before the
/// permission: without a front camera the source is unavailable whatever the permission
/// says, so the run ends `unsupported_device` (7.12) without asking for the camera.
final class FrontCameraSource: FrameSource, @unchecked Sendable {
    /// The device has the front camera spec 07 7.29 opens.
    static var available: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    let camera: any FrameSource
    let present: Bool

    init(_ camera: any FrameSource, present: Bool) {
        self.camera = camera
        self.present = present
    }

    /// The camera's, which the runner copies into `run.camera` (spec 07 7.29, 05 5.3).
    var format: CaptureFormat? {
        camera.format
    }

    func start(
        queue: DispatchQueue, handler: @escaping (CapturedFrame) -> Void
    ) throws(FrameSourceError) {
        guard present else { throw .unavailable }
        try camera.start(queue: queue, handler: handler)
    }

    func stop() {
        camera.stop()
    }
}
