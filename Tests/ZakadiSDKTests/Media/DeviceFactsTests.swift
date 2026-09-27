import VideoToolbox
import XCTest

@_spi(Testing) @testable import ZakadiSDK
@_spi(Testing) @testable import ZakadiSDKTesting

/// The facts of the `device` line: sysctl, the capability checks of spec 07 7.3 and the
/// H.264 entries of `VTCopyVideoEncoderList`.
final class DeviceFactsTests: XCTestCase {
    func testTheFactsComeFromSysctlTheChecksAndVideoToolbox() async {
        let facts = await DeviceFacts.collect(preference: .any)
        XCTAssertEqual(facts.machine, DeviceFacts.sysctl("hw.machine"))
        XCTAssertNotNil(facts.machine)
        XCTAssertNotNil(facts.osBuild)
        XCTAssertNil(DeviceFacts.sysctl("zakadi.no.such.name"))
        XCTAssertTrue(facts.check.encoderSession, "a session at 480x640")
        XCTAssertGreaterThan(facts.check.configureMs, 0)
        XCTAssertFalse(facts.encoders.isEmpty)
        XCTAssertTrue(facts.encoders.allSatisfy { !$0.encoderID.isEmpty })
        XCTAssertTrue(["nominal", "fair", "serious", "critical"].contains(facts.thermal))
        XCTAssertGreaterThan(facts.memoryMb, 0)
    }

    func testAnEncoderEntryReadsItsSupportedProperties() {
        var info = EncoderInfo(encoderID: "anon-2", hardwareAccelerated: false)
        info.read([
            kVTCompressionPropertyKey_ProfileLevel as String: [
                kVTPropertySupportedValueListKey as String: [
                    "H264_Baseline_AutoLevel", "H264_Baseline_3_1", "H264_Baseline_5_2",
                    "H264_Main_5_1",
                ]
            ]
        ])
        XCTAssertEqual(info.constrainedBaseline, false)
        XCTAssertEqual(info.maxBaselineLevel, "5.2")
        XCTAssertEqual(info.constantBitRate, false)
        info.read(nil)
        XCTAssertEqual(info.maxBaselineLevel, "5.2", "nothing read, nothing changed")
        XCTAssertEqual(EncoderInfo.baselineLevel("H264_Baseline_1_3")?.name, "1.3")
        XCTAssertNil(EncoderInfo.baselineLevel("H264_Baseline_AutoLevel"))
        XCTAssertNil(EncoderInfo.baselineLevel("H264_Main_3_1"))
    }
}
