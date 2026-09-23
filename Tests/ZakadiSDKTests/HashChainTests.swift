import Foundation
import XCTest

@testable import ZakadiSDK

/// The `attest` hash chain against `vectors/chain` of `zakadi-protocol` v0.1.0 (spec 01
/// 1.4 `attest`).
final class HashChainTests: XCTestCase {
    func testChainCasesReproduceEveryValue() throws {
        let cases = try Vectors.load("chain", as: ChainCase.self)
        XCTAssertEqual(cases.count, 3)
        for vector in cases {
            let jti = try XCTUnwrap(Data(base64URLEncoded: vector.jti), vector.name)
            XCTAssertEqual(try HashChain.jti(fromToken: vector.token), jti, vector.name)
            var chain = try HashChain(sessionId: vector.sessionId, token: vector.token)
            XCTAssertEqual(chain.hex, vector.initialValue, vector.name)
            for (index, step) in vector.messages.enumerated() {
                let message = try MediaMessage(decoding: XCTUnwrap(Data(hex: step.hex)))
                let chained = chain.append(message)
                XCTAssertEqual(chained, step.chained, "\(vector.name) message \(index)")
                XCTAssertEqual(chain.hex, step.chainAfter, "\(vector.name) message \(index)")
            }
            XCTAssertEqual(chain.hex, vector.attest.chain, vector.name)
        }
    }

    func testUnreadableTokensAreRefused() throws {
        func token(claims: String) -> String {
            let payload = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "e30.\(payload).c2ln"
        }
        let refusals: [(String, TokenError)] = [
            ("", .malformed),
            ("e30.e30", .malformed),
            ("e30.%%%.c2ln", .malformed),
            (token(claims: "{}"), .malformed),
            (token(claims: #"{"jti":16}"#), .malformed),
            (token(claims: #"{"jti":"AAECAwQFBgcICQoLDA0O"}"#), .invalidJTI),
        ]
        for (token, expected) in refusals {
            XCTAssertThrowsError(try HashChain.jti(fromToken: token), token) { error in
                XCTAssertEqual(error as? TokenError, expected, token)
            }
        }
    }
}
