import XCTest

@testable import ZakadiSDK

/// The header codec and payload parsers against `vectors/framing` of `zakadi-protocol`
/// v0.1.0 (spec 01 1.3 and 1.12).
final class FramingTests: XCTestCase {
    func testTheVectorSetIsTheV010One() throws {
        let cases = try Vectors.load("framing", as: FramingCase.self)
        XCTAssertEqual(cases.count, 18)
        XCTAssertEqual(cases.filter { $0.expect != nil }.count, 10)
        XCTAssertEqual(cases.filter { $0.error != nil }.count, 8)
        let names = Set(cases.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["seq-max", "seq-wrapped", "pts-max"]))
    }

    func testValidCasesDecodeAndReencode() throws {
        for vector in try Vectors.load("framing", as: FramingCase.self) {
            guard let expect = vector.expect else { continue }
            XCTAssertEqual(expect.header.ver, MediaHeader.version, vector.name)
            let header = try expect.header.mediaHeader()
            let payload = try XCTUnwrap(Data(hex: expect.payloadHex), vector.name)
            let decoded = try MediaMessage(decoding: XCTUnwrap(Data(hex: vector.hex)))
            XCTAssertEqual(decoded.header, header, vector.name)
            XCTAssertEqual(decoded.payload.lowercaseHex, expect.payloadHex, vector.name)
            let encoded = try MediaMessage(header: header, payload: payload).bytes
            XCTAssertEqual(encoded.lowercaseHex, vector.hex, vector.name)
            XCTAssertEqual(encoded, try Vectors.bin("framing", vector.name), vector.name)
        }
    }

    func testSeqStepsFrom65535To0() throws {
        let cases = try Vectors.load("framing", as: FramingCase.self)
        func seq(_ name: String) throws -> UInt16 {
            let vector = try XCTUnwrap(cases.first { $0.name == name }, name)
            return try MediaMessage(decoding: XCTUnwrap(Data(hex: vector.hex))).header.seq
        }
        XCTAssertEqual(try seq("seq-max"), UInt16.max)
        XCTAssertEqual(try seq("seq-wrapped"), 0)
        XCTAssertEqual(MediaHeader.seq(after: try seq("seq-max")), try seq("seq-wrapped"))
    }

    func testProbeAndBatchCasesYieldTheirContent() throws {
        var probes = 0
        var batches = 0
        for vector in try Vectors.load("framing", as: FramingCase.self) {
            guard let expect = vector.expect else { continue }
            let payload = try MediaMessage(decoding: XCTUnwrap(Data(hex: vector.hex))).payload
            if let sendTimeUs = expect.probeSendTimeUs {
                probes += 1
                XCTAssertEqual(try ProbePayload(parsing: payload).sendTimeUs, sendTimeUs)
            }
            if let records = expect.audioBatch {
                batches += 1
                let parsed = try AudioBatchPayload(parsing: payload).records
                XCTAssertEqual(parsed.map(\.ptsDeltaMs), records.map(\.ptsDeltaMs), vector.name)
                XCTAssertEqual(
                    parsed.map(\.packet.lowercaseHex), records.map(\.packetHex), vector.name)
            }
        }
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(batches, 1)
    }

    func testInvalidCasesFailWithTheirCode() throws {
        for vector in try Vectors.load("framing", as: FramingCase.self) {
            guard let code = vector.error else { continue }
            let bytes = try XCTUnwrap(Data(hex: vector.hex), vector.name)
            XCTAssertThrowsError(try MediaMessage(decoding: bytes), vector.name) { error in
                XCTAssertEqual((error as? FramingError)?.rawValue, code, vector.name)
            }
        }
    }

    func testTheEncoderRefusesARungAboveFifteen() {
        let header = MediaHeader(type: .video, rung: 16, seq: 0, ptsMs: 0)
        XCTAssertThrowsError(try header.encoded()) { error in
            XCTAssertEqual(error as? FramingError, .badRung)
        }
    }
}
