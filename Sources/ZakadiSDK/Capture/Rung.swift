/// One rung of `ready.ladder` (spec 01 1.5): the size frames are encoded at, the frame rate
/// the pacer keeps and the video bitrate.
@_spi(Testing) public struct Rung: Sendable, Equatable {
    /// The rung number, 0 the highest.
    public var index: Int
    public var width: Int
    public var height: Int
    public var fps: Int
    public var videoKbps: Int

    public init(index: Int, width: Int, height: Int, fps: Int, videoKbps: Int) {
        self.index = index
        self.width = width
        self.height = height
        self.fps = fps
        self.videoKbps = videoKbps
    }

    /// The ladder of the `ready` example in spec 01 1.5.
    public static let exampleLadder = [
        Rung(index: 0, width: 480, height: 640, fps: 20, videoKbps: 900),
        Rung(index: 1, width: 480, height: 640, fps: 20, videoKbps: 600),
        Rung(index: 2, width: 480, height: 640, fps: 15, videoKbps: 400),
        Rung(index: 3, width: 336, height: 448, fps: 12, videoKbps: 250),
        Rung(index: 4, width: 288, height: 384, fps: 10, videoKbps: 150),
    ]
}
