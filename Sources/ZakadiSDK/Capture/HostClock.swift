import CoreMedia

/// The host time clock (spec 07 7.5): the clock a capture session stamps sample buffers on
/// when its synchronization clock is the host time clock, and the monotonic clock the
/// pipeline stamps its events with.
@_spi(Testing) public enum HostClock {
    /// The current host time.
    public static var now: CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    /// The current host time in whole microseconds.
    public static var nowMicroseconds: Int64 {
        microseconds(now)
    }

    /// `time` in whole microseconds, rounded half away from zero.
    public static func microseconds(_ time: CMTime) -> Int64 {
        CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value
    }

    /// Whether `clock` reads the host time: it is the host time clock, or its time is
    /// within 1 ms of it. Only then are frame times comparable with the event times.
    public static func isHost(_ clock: CMClock) -> Bool {
        if CFEqual(clock, CMClockGetHostTimeClock()) { return true }
        return abs((CMClockGetTime(clock) - now).seconds) < 0.001
    }
}
