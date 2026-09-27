import Foundation
@_spi(Testing) import ZakadiSDK

#if canImport(UIKit)
    import UIKit
#endif

/// The battery as the device reports it: each nil where it cannot tell, as on the simulator.
@_spi(Testing) public struct Battery: Sendable, Equatable {
    public var percent: Int?
    public var charging: Bool?

    public init(percent: Int?, charging: Bool?) {
        self.percent = percent
        self.charging = charging
    }

    /// `UIDevice` battery level and state on iOS; nothing elsewhere.
    public static func read() async -> Battery {
        #if canImport(UIKit)
            return await MainActor.run {
                let device = UIDevice.current
                device.isBatteryMonitoringEnabled = true
                let level = device.batteryLevel
                let charging: Bool? =
                    switch device.batteryState {
                    case .charging, .full: true
                    case .unplugged: false
                    default: nil
                    }
                return Battery(
                    percent: level < 0 ? nil : Int((level * 100).rounded()), charging: charging)
            }
        #else
            return Battery(percent: nil, charging: nil)
        #endif
    }
}

/// The facts the `device` line of the encoder log carries on iOS (Z-064's Spec with the
/// iOS values of Z-068): identifiers of the model and the build only, nothing of the user.
@_spi(Testing) public struct DeviceFacts: Sendable, Equatable {
    public var wallMs: Int64
    /// `hw.machine`, for both `phone` and `soc`.
    public var machine: String?
    public var osVersion: String
    /// `kern.osversion`.
    public var osBuild: String?
    public var memoryMb: Int
    public var check: CapabilityCheck
    public var encoders: [EncoderInfo]
    public var thermal: String
    public var battery: Battery

    /// Reads every fact now; the session check runs with `preference`.
    public static func collect(preference: EncoderPreference) async -> DeviceFacts {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return DeviceFacts(
            wallMs: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)),
            machine: sysctl("hw.machine"),
            osVersion: "\(version.majorVersion).\(version.minorVersion)\(patch)",
            osBuild: sysctl("kern.osversion"),
            memoryMb: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            check: CapabilityCheck.run(preference: preference), encoders: EncoderInfo.h264(),
            thermal: thermalState(), battery: await Battery.read())
    }

    /// `ProcessInfo.thermalState` by its name, as spec 07 7.7 reports it on iOS.
    public static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// A string sysctl value, or nil.
    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(
            bytes: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
