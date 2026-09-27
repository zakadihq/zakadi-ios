#if os(iOS)
    import AVFoundation

    /// The front camera of spec 07 7.29 behind `FrameSource`: 420v frames in the format
    /// `CaptureSettings.bestFormat` picks for 640x480, rotated upright and unmirrored by the
    /// connection, at frame durations of 1/`maxFps` to 1/15 s, with +0.3 EV within the
    /// device's range and auto exposure metered at `exposurePoint`. The preview, mirrored,
    /// is the host's: it attaches a layer to `session`.
    @_spi(Testing)
    public final class CameraFrameSource: NSObject, FrameSource, @unchecked Sendable {
        public let session = AVCaptureSession()
        public private(set) var format: CaptureFormat?
        /// `device_quirks.max_fps`.
        public let maxFps: Int
        /// In device coordinates (landscape, unrotated): the oval centre.
        public let exposurePoint: CGPoint
        private let output = AVCaptureVideoDataOutput()
        private var handler: ((CapturedFrame) -> Void)?

        public init(maxFps: Int = 30, exposurePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
            self.maxFps = maxFps
            self.exposurePoint = exposurePoint
        }

        public func start(
            queue: DispatchQueue, handler: @escaping (CapturedFrame) -> Void
        ) throws(FrameSourceError) {
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw .notAuthorized
            }
            guard
                let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: .front)
            else { throw .unavailable }
            session.beginConfiguration()
            session.automaticallyConfiguresApplicationAudioSession = false  // keep 7.31's
            do {
                try addInput(camera)
            } catch {
                session.commitConfiguration()
                throw error
            }
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: CaptureSettings.pixelFormat
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
            let rotation = orient(output.connection(with: .video))
            let applied = configure(camera)
            session.commitConfiguration()
            self.handler = handler
            session.startRunning()
            format = captureFormat(camera, rotation: rotation, exposureBias: applied)
        }

        public func stop() {
            session.stopRunning()
            handler = nil
        }

        private func addInput(_ camera: AVCaptureDevice) throws(FrameSourceError) {
            guard let input = try? AVCaptureDeviceInput(device: camera),
                session.canAddInput(input), session.canAddOutput(output)
            else { throw .configuration("the front camera input or the video output") }
            session.addInput(input)
        }

        /// Upright and unmirrored in hardware (spec 05 5.3): the rotation coordinator's
        /// horizon-level angle from iOS 17, portrait below; returns the degrees applied.
        private func orient(_ connection: AVCaptureConnection?) -> Int {
            guard let connection else { return 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if #available(iOS 17, *) {
                let angle = portraitAngle()
                guard connection.isVideoRotationAngleSupported(angle) else { return 0 }
                connection.videoRotationAngle = angle
                return Int(angle)
            }
            guard connection.isVideoOrientationSupported else { return 0 }
            connection.videoOrientation = .portrait
            return 90
        }

        @available(iOS 17, *)
        private func portraitAngle() -> CGFloat {
            guard let camera = (session.inputs.first as? AVCaptureDeviceInput)?.device else {
                return 90
            }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            return coordinator.videoRotationAngleForHorizonLevelCapture
        }

        /// The format, the frame durations, the exposure bias and the metering point of
        /// spec 07 7.29; returns the bias applied, nil when the device is locked.
        private func configure(_ camera: AVCaptureDevice) -> Float? {
            guard (try? camera.lockForConfiguration()) != nil else { return nil }
            defer { camera.unlockForConfiguration() }
            let candidates = camera.formats.map { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return FormatCandidate(
                    width: dimensions.width, height: dimensions.height,
                    pixelFormat: CMFormatDescriptionGetMediaSubType(format.formatDescription))
            }
            if let index = CaptureSettings.bestFormat(candidates, width: 640, height: 480) {
                camera.activeFormat = camera.formats[index]
            }
            let durations = CaptureSettings.frameDurations(
                maxFps: maxFps,
                supported: camera.activeFormat.videoSupportedFrameRateRanges.map {
                    FrameDurations(min: $0.minFrameDuration, max: $0.maxFrameDuration)
                })
            camera.activeVideoMinFrameDuration = durations.min
            camera.activeVideoMaxFrameDuration = durations.max
            let bias = CaptureSettings.exposureBias(
                min: camera.minExposureTargetBias, max: camera.maxExposureTargetBias)
            camera.setExposureTargetBias(bias)
            if camera.isExposurePointOfInterestSupported {
                camera.exposurePointOfInterest = exposurePoint
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            return bias
        }

        private func captureFormat(
            _ camera: AVCaptureDevice, rotation: Int, exposureBias: Float?
        ) -> CaptureFormat {
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                camera.activeFormat.formatDescription)
            let turned = rotation % 180 != 0
            let slowest = camera.activeVideoMaxFrameDuration.seconds
            let fastest = camera.activeVideoMinFrameDuration.seconds
            let low = slowest > 0 ? 1 / slowest : 0
            let high = fastest > 0 ? 1 / fastest : 0
            let clock: CMClock?
            if #available(iOS 15.4, *) {
                clock = session.synchronizationClock
            } else {
                clock = session.masterClock
            }
            return CaptureFormat(
                width: Int(turned ? dimensions.height : dimensions.width),
                height: Int(turned ? dimensions.width : dimensions.height), rotation: rotation,
                fps: min(low, high)...max(low, high),
                exposureBias: exposureBias, hostClock: clock.map(HostClock.isHost) ?? false)
        }
    }

    extension CameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
        public func captureOutput(
            _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            handler?(
                CapturedFrame(
                    pixelBuffer: pixelBuffer,
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        }
    }
#endif
