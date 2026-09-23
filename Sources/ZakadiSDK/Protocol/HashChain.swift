import CryptoKit
import Foundation

/// The media hash chain the client reports in `attest` (spec 01 1.4). H0 is the SHA-256
/// of the UTF-8 session id followed by the 16 `jti` bytes, with no separator; every video,
/// audio and audio batch message, in send order, replaces the value with the SHA-256 of
/// the previous value, the 8 header bytes and the payload. Probes leave it unchanged.
struct HashChain {
    /// The latest value: H0 until the first chained message.
    private(set) var value: Data

    /// Starts the chain of a session, reading `jti` from its client token unverified.
    init(sessionId: String, token: String) throws(TokenError) {
        let jti = try Self.jti(fromToken: token)
        value = Data(SHA256.hash(data: Data(sessionId.utf8) + jti))
    }

    /// `attest.chain`: the latest value as lowercase hex.
    var hex: String {
        value.lowercaseHex
    }

    /// Hashes `message` into the chain when its type is video, audio or audio batch and
    /// returns whether it did; a probe leaves the chain unchanged.
    @discardableResult
    mutating func append(_ message: MediaMessage) -> Bool {
        guard message.header.type != .probe else { return false }
        var hash = SHA256()
        hash.update(data: value)
        hash.update(data: message.bytes)
        value = Data(hash.finalize())
        return true
    }

    /// The 16 raw bytes of the token's `jti` claim (base64url without padding, spec 02
    /// 2.2), read from the payload segment without verifying the token, as in spec 07 7.5.
    static func jti(fromToken token: String) throws(TokenError) -> Data {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
            let payload = Data(base64URLEncoded: segments[1]),
            let claims = try? JSONDecoder().decode(TokenClaims.self, from: payload)
        else { throw .malformed }
        guard let jti = Data(base64URLEncoded: claims.jti), jti.count == 16 else {
            throw .invalidJTI
        }
        return jti
    }
}

/// Why the `jti` of a client token cannot be read. The client never verifies the token.
enum TokenError: Error {
    /// Not three dot-separated segments whose middle one is base64url JSON carrying a
    /// string `jti`.
    case malformed
    /// The `jti` claim does not decode to 16 bytes.
    case invalidJTI
}

private struct TokenClaims: Decodable {
    let jti: String
}

extension Data {
    /// Decodes base64url (RFC 4648 section 5), with or without padding.
    init?(base64URLEncoded text: some StringProtocol) {
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    /// The bytes as lowercase hex, two digits each.
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
