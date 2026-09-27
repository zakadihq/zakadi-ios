import CoreMedia
import Foundation
import VideoToolbox

/// One H.264 entry of `VTCopyVideoEncoderList` with what its supported properties say at
/// 480x640, each nil where VideoToolbox does not list it.
@_spi(Testing) public struct EncoderInfo: Sendable, Equatable {
    /// `EncoderID`: what `kVTVideoEncoderSpecification_EncoderID` takes.
    public var encoderID: String
    /// `IsHardwareAccelerated`; the list omits it for software encoders.
    public var hardwareAccelerated: Bool
    /// `ConstantBitRate` is a supported property (iOS 16 and later).
    public var constantBitRate: Bool?
    /// `H264_ConstrainedBaseline_AutoLevel` is a supported `ProfileLevel`.
    public var constrainedBaseline: Bool?
    /// The highest `H264_Baseline_<level>` supported, as `3.1`.
    public var maxBaselineLevel: String?

    public init(encoderID: String, hardwareAccelerated: Bool) {
        self.encoderID = encoderID
        self.hardwareAccelerated = hardwareAccelerated
    }

    /// Every H.264 encoder VideoToolbox lists, in its order.
    public static func h264() -> [EncoderInfo] {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let entries = list as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            let codec = (entry[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
            guard codec == kCMVideoCodecType_H264,
                let encoderID = entry[kVTVideoEncoderList_EncoderID as String] as? String
            else { return nil }
            let hardware = entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool
            var info = EncoderInfo(encoderID: encoderID, hardwareAccelerated: hardware ?? false)
            info.read(supportedProperties(encoderID))
            return info
        }
    }

    /// Fills the optional fields from an encoder's supported properties.
    mutating func read(_ properties: [String: Any]?) {
        guard let properties else { return }
        if #available(iOS 16, macOS 13, *) {
            constantBitRate = properties[kVTCompressionPropertyKey_ConstantBitRate as String] != nil
        }
        let profileLevel = properties[kVTCompressionPropertyKey_ProfileLevel as String]
        let values = (profileLevel as? [String: Any])?[kVTPropertySupportedValueListKey as String]
        guard let levels = values as? [String] else { return }
        constrainedBaseline = levels.contains(
            kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel as String)
        maxBaselineLevel = levels.compactMap(Self.baselineLevel).max { $0.value < $1.value }?.name
    }

    /// `H264_Baseline_3_1` as the level `3.1` and its number; nil for other values.
    static func baselineLevel(_ value: String) -> (name: String, value: Double)? {
        let prefix = "H264_Baseline_"
        guard value.hasPrefix(prefix) else { return nil }
        let name = value.dropFirst(prefix.count).replacingOccurrences(of: "_", with: ".")
        guard let number = Double(name) else { return nil }
        return (name, number)
    }

    private static func supportedProperties(_ encoderID: String) -> [String: Any]? {
        var properties: CFDictionary?
        let specification = [kVTVideoEncoderSpecification_EncoderID: encoderID] as CFDictionary
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 480, height: 640, codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, encoderIDOut: nil,
            supportedPropertiesOut: &properties)
        return status == noErr ? properties as? [String: Any] : nil
    }
}
