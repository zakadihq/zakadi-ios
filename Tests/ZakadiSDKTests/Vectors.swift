import Foundation
import XCTest

@testable import ZakadiSDK

/// The `zakadi-protocol` conformance vectors that `scripts/fetch-vectors.sh` unpacks into
/// `vectors/` at the repository root (spec 01 1.12).
enum Vectors {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vectors")

    /// Every `<kind>/*.json` case in file-name order; throws when the directory is missing.
    static func load<Case: Decodable>(_ kind: String, as _: Case.Type) throws -> [Case] {
        let directory = root.appendingPathComponent(kind)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw MissingVectors(directory: directory)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decoder.decode(Case.self, from: Data(contentsOf: $0)) }
    }

    /// The `.bin` file that ships beside a valid `<kind>/<name>.json` case.
    static func bin(_ kind: String, _ name: String) throws -> Data {
        let file = root.appendingPathComponent(kind).appendingPathComponent(name + ".bin")
        return try Data(contentsOf: file)
    }
}

struct MissingVectors: Error, CustomStringConvertible {
    let directory: URL

    var description: String {
        "\(directory.path) is missing: run scripts/fetch-vectors.sh first"
    }
}

/// A `framing/*.json` case: `hex` with either `expect` or `error`.
struct FramingCase: Decodable {
    let name: String
    let hex: String
    let expect: FramingExpectation?
    let error: String?
}

struct FramingExpectation: Decodable {
    let header: HeaderFields
    let payloadHex: String
    let probeSendTimeUs: UInt64?
    let audioBatch: [BatchRecordFields]?
}

struct HeaderFields: Decodable {
    let ver: UInt8
    let type: UInt8
    let keyframe: Bool
    let paramSets: Bool
    let rungChanged: Bool
    let rung: UInt8
    let seq: UInt16
    let ptsMs: UInt32

    func mediaHeader() throws -> MediaHeader {
        MediaHeader(
            type: try XCTUnwrap(MediaType(rawValue: type)),
            keyframe: keyframe,
            paramSets: paramSets,
            rungChanged: rungChanged,
            rung: rung,
            seq: seq,
            ptsMs: ptsMs
        )
    }
}

struct BatchRecordFields: Decodable {
    let ptsDeltaMs: UInt16
    let packetHex: String
}

/// A `chain/*.json` case: a session id, a token carrying the jti, H0, the media messages
/// in send order with the chain after each, and the resulting `attest`.
struct ChainCase: Decodable {
    enum CodingKeys: String, CodingKey {
        case name, sessionId, jti, token, messages, attest
        case initialValue = "h0"
    }

    let name: String
    let sessionId: String
    let jti: String
    let token: String
    let initialValue: String
    let messages: [ChainStep]
    let attest: AttestFields
}

struct ChainStep: Decodable {
    let hex: String
    let chained: Bool
    let chainAfter: String
}

struct AttestFields: Decodable {
    let chain: String
}

extension Data {
    /// Bytes from the lowercase hex the vectors use; nil for anything else.
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next > hex.index(after: index), let byte = UInt8(hex[index..<next], radix: 16)
            else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
