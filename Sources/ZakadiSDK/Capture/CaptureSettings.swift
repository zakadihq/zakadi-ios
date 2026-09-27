import CoreMedia
import CoreVideo

/// A camera format as the choice of spec 07 7.8 and 7.29 sees it: its dimensions in sensor
/// orientation and its pixel format.
@_spi(Testing) public struct FormatCandidate: Sendable, Equatable {
    public var width: Int32
    public var height: Int32
    public var pixelFormat: FourCharCode

    public init(width: Int32, height: Int32, pixelFormat: FourCharCode) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }
}

/// A range of frame durations: `min` is the fastest frame rate, `max` the slowest.
@_spi(Testing) public struct FrameDurations: Sendable, Equatable {
    public var min: CMTime
    public var max: CMTime

    public init(min: CMTime, max: CMTime) {
        self.min = min
        self.max = max
    }
}

/// The capture settings of spec 07 7.29, as pure functions of what the camera offers.
@_spi(Testing) public enum CaptureSettings {
    /// 420v: the pixel format of the capture output and of the encoder input.
    public static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    /// Auto exposure may lower the frame rate to 15 fps in low light.
    public static let minFps = 15
    /// +0.3 EV (spec 05 5.3).
    public static let exposureBias: Float = 0.3

    /// The index of the 420v format with the smallest size at or above `width` x `height`,
    /// else of the largest 420v format (spec 07 7.8), the first listed on a tie; nil
    /// without a 420v format.
    public static func bestFormat(
        _ formats: [FormatCandidate], width: Int32, height: Int32
    ) -> Int? {
        func area(_ index: Int) -> Int64 {
            Int64(formats[index].width) * Int64(formats[index].height)
        }
        let candidates = formats.indices.filter { formats[$0].pixelFormat == pixelFormat }
        let above = candidates.filter {
            formats[$0].width >= width && formats[$0].height >= height
        }
        if let smallest = above.min(by: { area($0) < area($1) }) { return smallest }
        return candidates.max { area($0) < area($1) }
    }

    /// Frame durations from 1/`maxFps` to 1/15 s (spec 07 7.29), each moved to the nearest
    /// supported duration when no supported range holds it, since the camera refuses an
    /// unsupported one (7.8); the second never shorter than the first.
    public static func frameDurations(
        maxFps: Int, supported: [FrameDurations]
    ) -> FrameDurations {
        let lower = nearest(CMTime(value: 1, timescale: CMTimeScale(maxFps)), supported)
        let upper = nearest(CMTime(value: 1, timescale: CMTimeScale(minFps)), supported)
        return FrameDurations(min: lower, max: Swift.max(upper, lower))
    }

    /// `duration` when a range holds it or none is known, else the closest range end.
    static func nearest(_ duration: CMTime, _ ranges: [FrameDurations]) -> CMTime {
        guard !ranges.contains(where: { $0.min <= duration && duration <= $0.max }) else {
            return duration
        }
        let ends = ranges.flatMap { [$0.min, $0.max] }
        return ends.min { abs(($0 - duration).seconds) < abs(($1 - duration).seconds) } ?? duration
    }

    /// +0.3 EV within the device's exposure target bias range (spec 05 5.3, 07 7.29).
    public static func exposureBias(min: Float, max: Float) -> Float {
        Swift.min(Swift.max(exposureBias, min), max)
    }
}
