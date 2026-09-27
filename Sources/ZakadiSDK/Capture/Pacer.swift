import CoreMedia

/// The pacer of spec 07 7.18, which iOS matches (7.29): frames reach the encoder at the
/// rung frame rate, capped by `device_quirks.max_fps`, and decimation drops a share of
/// those before encoding.
///
/// Slots fall one frame interval apart from the first frame. A frame is kept when it is
/// no earlier than 3 ms before the next slot, and fills it; a frame a whole interval or
/// more behind its slot restarts the slots at itself, so a stall is never followed by a
/// burst. Decimation 1 then drops every 4th kept frame and decimation 2 every 2nd,
/// counting from the last change of level.
@_spi(Testing) public struct Pacer: Sendable {
    /// What happens to a frame before encoding.
    public enum Decision: Sendable, Equatable {
        case keep
        /// Earlier than 3 ms before its slot.
        case pacing
        /// Kept by the slots, then dropped by decimation.
        case decimation
    }

    /// How early a frame may come for its slot.
    public static let tolerance = CMTime(value: 3, timescale: 1000)

    /// The frame rate the slots follow.
    public private(set) var fps: Int
    /// 0, 1 or 2.
    public private(set) var decimation: Int
    private var nextSlot: CMTime?
    private var kept = 0

    public init(fps: Int, decimation: Int = 0) {
        self.fps = fps
        self.decimation = decimation
    }

    /// A new rate from the next slot on.
    public mutating func setFps(_ fps: Int) {
        self.fps = fps
    }

    /// A new decimation level, counted afresh.
    public mutating func setDecimation(_ level: Int) {
        decimation = level
        kept = 0
    }

    /// Whether the frame at `time` goes to the encoder.
    public mutating func decide(_ time: CMTime) -> Decision {
        let slot = nextSlot ?? time
        guard time >= slot - Self.tolerance else { return .pacing }
        let interval = CMTime(value: 1, timescale: CMTimeScale(fps))
        let following = slot + interval
        nextSlot = following > time ? following : time + interval
        guard decimation > 0 else { return .keep }
        kept += 1
        return kept % (decimation == 1 ? 4 : 2) == 0 ? .decimation : .keep
    }
}
