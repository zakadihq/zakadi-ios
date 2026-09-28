import AVFoundation
import SwiftUI

/// The self-view of spec 07 7.34: the camera session's preview layer, filling its frame and
/// mirrored (7.29), while the frames the encoder takes stay unmirrored (05 5.3).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView {
        PreviewView()
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.show(session)
    }
}

/// A view whose layer is the preview layer.
final class PreviewView: UIView {
    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    private var running: NSKeyValueObservation?

    private var preview: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    func show(_ session: AVCaptureSession?) {
        guard let preview, preview.session !== session else { return }
        preview.videoGravity = .resizeAspectFill
        preview.session = session
        running = session.map(mirrorOnStart)
    }

    /// Mirrors the preview once `session` runs: the layer's connection exists only once the
    /// session has the camera.
    private func mirrorOnStart(_ session: AVCaptureSession) -> NSKeyValueObservation {
        session.observe(\.isRunning, options: [.initial, .new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.mirror() }
        }
    }

    private func mirror() {
        guard let connection = preview?.connection, connection.isVideoMirroringSupported else {
            return
        }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
