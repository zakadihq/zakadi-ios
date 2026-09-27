import Foundation
import XCTest

@_spi(Testing) @testable import ZakadiSDK
@_spi(Testing) @testable import ZakadiSDKTesting

/// Log format 1 as Z-064's Spec fixes it, with the values iOS reads (Z-068's Spec): every
/// line kind with its keys in order and `null` where iOS cannot read a value.
final class ProbeLineTests: XCTestCase {
    private func assertLine(_ line: JSONValue, _ expected: String, line number: UInt = #line) {
        XCTAssertEqual(line.serialized, expected, line: number)
        let data = Data(expected.utf8)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), line: number)
    }

    func testTheDeviceLine() {
        var encoder = EncoderInfo(
            encoderID: "com.apple.videotoolbox.videoencoder.ave.avc", hardwareAccelerated: true)
        encoder.constantBitRate = true
        encoder.constrainedBaseline = true
        encoder.maxBaselineLevel = "5.2"
        let facts = DeviceFacts(
            wallMs: 1_790_000_000_000, machine: "iPhone12,8", osVersion: "17.4",
            osBuild: "21E219", memoryMb: 2_868,
            check: CapabilityCheck(frontCamera: true, encoderSession: true, configureMs: 12.5),
            encoders: [encoder], thermal: "nominal", battery: Battery(percent: 81, charging: false))
        let options = ProbeOptions(
            directory: URL(fileURLWithPath: "/tmp"), sourceName: "camera")
        assertLine(
            ProbeLine.device(facts, schedule: 1, args: options.args),
            #"{"v":1,"kind":"device","t_us":0,"wall_ms":1790000000000,"platform":"ios","#
                + #""phone":"iPhone12,8","soc":"iPhone12,8","os":"17.4","os_build":"21E219","#
                + #""schedule":1,"args":{"source":"camera","encoder":"hardware","max_fps":30,"#
                + #""divisor":1},"tier":"S","low_ram":null,"mem_mb":2868,"camera_level":null,"#
                + #""egl_recordable":null,"front_camera":true,"configure_ms":12.5,"encoders":[{"#
                + #""name":"com.apple.videotoolbox.videoencoder.ave.avc","hw":true,"vendor":null,"#
                + #""alias":null,"cbr":true,"cb":true,"max_level":"5.2","rungs":null,"#
                + #""kbps_range":null,"achievable_fps":null}],"thermal":"nominal","#
                + #""battery_pct":81,"charging":false}"#)
    }

    func testAnUnsupportedDeviceIsTierU() {
        let check = CapabilityCheck(frontCamera: false, encoderSession: true, configureMs: 3)
        XCTAssertEqual(check.tier, .unsupported)
        XCTAssertEqual(
            CapabilityCheck(frontCamera: true, encoderSession: false, configureMs: 3).tier,
            .unsupported)
        XCTAssertEqual(
            CapabilityCheck(frontCamera: true, encoderSession: true, configureMs: 3).tier,
            .standard)
    }

    func testTheRunLineAfterTheFallbackToBaseline() {
        var readBack = EncoderReadBack()
        readBack.profileLevel = "H264_Baseline_AutoLevel"
        readBack.averageBitRate = 400_000
        readBack.dataRateLimits = [75_000, 1]
        readBack.expectedFrameRate = 15
        readBack.maxKeyFrameInterval = 30
        readBack.maxKeyFrameIntervalDuration = 2
        readBack.realTime = true
        readBack.allowFrameReordering = false
        let report = EncoderReport(
            settings: EncoderSettings(rung: Rung.exampleLadder[2]), profile: .baseline,
            refused: [.constrainedBaseline], encoderID: "anon-2", usingHardware: nil,
            readBack: readBack)
        let run = RunDescription(
            index: 2, run: ProbeSchedule.one.runs[2], gopMs: 2_000, report: report,
            camera: CaptureFormat(
                width: 480, height: 640, rotation: 90, fps: 15...30, exposureBias: 0.3,
                hostClock: true),
            firstFrame: 1_234_567, thermal: "fair")
        assertLine(
            ProbeLine.run(run, at: 2_000),
            #"{"v":1,"kind":"run","t_us":2000,"run":2,"mode":"constant","rung":2,"w":480,"#
                + #""h":640,"fps":15,"kbps":400,"gop_ms":2000,"path":null,"encoder":"anon-2","#
                + #""hw":null,"profile":"baseline","level":"auto","bitrate_mode":"abr","#
                + #""dropped":["constrained_baseline"],"out_format":{"#
                + #""profile_level":"H264_Baseline_AutoLevel","average_bit_rate":400000,"#
                + #""data_rate_limits":[75000,1],"expected_frame_rate":15,"#
                + #""max_key_frame_interval":30,"max_key_frame_interval_duration":2,"#
                + #""real_time":true,"allow_frame_reordering":false},"camera":{"w":480,"#
                + #""h":640,"rotation":90,"fps_min":15,"fps_max":30,"ev":0.3,"clock":"host"},"#
                + #""t0_us":1234567,"thermal":"fair"}"#)
    }

    func testTheHardwareFlagIsWrittenWhereReadAndNullWhereNot() {
        var report = EncoderReport(
            settings: EncoderSettings(rung: Rung.exampleLadder[0]), profile: .constrainedBaseline,
            refused: [], encoderID: nil, usingHardware: true, readBack: EncoderReadBack())
        func run() -> String {
            ProbeLine.run(
                RunDescription(
                    index: 0, run: ProbeSchedule.one.runs[0], gopMs: 2_000, report: report,
                    camera: nil, firstFrame: nil, thermal: "nominal"),
                at: 0
            ).serialized
        }
        XCTAssertTrue(run().contains(#""hw":true,"profile":"constrained_baseline""#))
        XCTAssertTrue(run().contains(#""dropped":[],"#))
        XCTAssertTrue(run().contains(#""camera":null,"t0_us":null,"#))
        report.usingHardware = nil
        XCTAssertTrue(run().contains(#""encoder":null,"hw":null,"#))
    }

    func testTheFrameLines() throws {
        let sets = ParameterSets(sps: AnnexBTests.sps, pps: AnnexBTests.pps)
        assertLine(
            ProbeLine.params(run: 2, sets: sets, at: 2_100),
            #"{"v":1,"kind":"params","t_us":2100,"run":2,"source":"format","#
                + #""sps":"2742e01ea9183c0a3602d4080808c2b5ef7c04","pps":"28de09c8","#
                + #""codec":"avc1.42E01E"}"#)
        assertLine(
            ProbeLine.input(run: 2, pts: 66_667, at: 2_200),
            #"{"v":1,"kind":"in","t_us":2200,"run":2,"pts_us":66667}"#)
        let idr = try XCTUnwrap(
            EncodedFrame(AnnexBTests.sampleBuffer(Data([0x65, 0x88, 0x84]), notSync: nil)))
        assertLine(
            ProbeLine.output(run: 2, pts: 66_667, frame: idr, at: 2_300),
            #"{"v":1,"kind":"out","t_us":2300,"run":2,"pts_us":66667,"bytes":7,"key":true,"#
                + #""flag_key":true,"param_sets":false,"sc3":null,"nal":[5]}"#)
        assertLine(
            ProbeLine.keyframeRequest(run: 2, number: 1, at: 2_400),
            #"{"v":1,"kind":"kf_req","t_us":2400,"run":2,"n":1,"repeat":false}"#)
        assertLine(
            ProbeLine.rate(run: 5, kbps: 200, at: 2_500),
            #"{"v":1,"kind":"rate","t_us":2500,"run":5,"kbps":200}"#)
    }

    func testTheTickRunEndAndEndLines() {
        var counts = TickCounts()
        counts.captured = 30
        counts.submitted = 15
        counts.encoded = 15
        counts.preEncodeDrops = 16
        counts.encodedKbps = 402.5
        counts.cpuMs = 41.25
        assertLine(
            ProbeLine.tick(run: 2, counts: counts, at: 1_002_000),
            #"{"v":1,"kind":"tick","t_us":1002000,"run":2,"captured":30,"submitted":15,"#
                + #""encoded":15,"pre_encode_drops":16,"enc_queue":0,"encoded_kbps":402.5,"#
                + #""thermal":"nominal","cpu_ms":41.25,"enc_dropped":0}"#)
        var totals = RunTotals()
        totals.inputs = 900
        totals.outputs = 900
        totals.idr = 31
        totals.bareIDR = 31
        totals.summary = ProbeSummary(
            deliveredKbps: 398.25, keyframeLatencyMs: 21.5, keyframeFrames: 1, minFps: 14)
        assertLine(
            ProbeLine.runEnd(run: 2, totals: totals, at: 60_002_000),
            #"{"v":1,"kind":"run_end","t_us":60002000,"run":2,"in":900,"out":900,"idr":31,"#
                + #""idr_bare":31,"delivered_kbps":398.25,"kf_latency_ms":21.5,"kf_frames":1,"#
                + #""min_fps":14,"error":null}"#)
        assertLine(
            ProbeLine.end(
                runs: 6, reason: .done, thermal: "nominal",
                battery: Battery(percent: nil, charging: nil), at: 160_000_000),
            #"{"v":1,"kind":"end","t_us":160000000,"runs":6,"reason":"done","#
                + #""thermal":"nominal","battery_pct":null}"#)
    }

    func testValuesAreWrittenAsASCII() {
        XCTAssertEqual(
            JSONValue.string("a\"b\\c\nd\u{E9}\u{1F600}").serialized,
            #""a\"b\\c\nd"# + ["00e9", "d83d", "de00"].map { "\\" + "u" + $0 }.joined() + "\"")
        XCTAssertEqual(
            [12.3456, 400, -0.0001, .nan].map { JSONValue.double($0).serialized },
            ["12.346", "400", "0", "null"])
    }
}
