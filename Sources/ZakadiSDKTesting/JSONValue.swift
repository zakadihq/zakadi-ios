import Foundation

/// A JSON value whose objects keep their keys in the order given: the encoder log lists
/// every line's keys in a fixed order, which `JSONSerialization` and `JSONEncoder` do not
/// promise before iOS 17.
@_spi(Testing) public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([JSONField])

    /// The value as one line of ASCII JSON: no whitespace, every character outside
    /// printable ASCII escaped, numbers with at most three decimals.
    public var serialized: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value): Self.number(value)
        case .string(let value): Self.quoted(value)
        case .array(let values): "[" + values.map(\.serialized).joined(separator: ",") + "]"
        case .object(let fields):
            "{"
                + fields.map { Self.quoted($0.key) + ":" + $0.value.serialized }.joined(
                    separator: ",")
                + "}"
        }
    }

    /// Three decimals at most, trailing zeros dropped; `null` for NaN and infinities.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func quoted(_ value: String) -> String {
        var text = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            default:
                if (0x20..<0x7F).contains(scalar.value) {
                    text.unicodeScalars.append(scalar)
                } else {
                    for unit in String(scalar).utf16 { text += String(format: "\\u%04x", unit) }
                }
            }
        }
        return text + "\""
    }
}

/// One key of a JSON object and its value.
@_spi(Testing) public struct JSONField: Sendable, Equatable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }

    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int64) {
        self = .int(value)
    }

    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue {
    /// An object from key and value pairs, in order.
    static func fields(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(pairs.map { JSONField($0.key, $0.value) })
    }

    static func of(_ value: Int?) -> JSONValue {
        value.map { .int(Int64($0)) } ?? .null
    }

    static func of(_ value: Int64?) -> JSONValue {
        value.map(JSONValue.int) ?? .null
    }

    static func of(_ value: Double?) -> JSONValue {
        value.map(JSONValue.double) ?? .null
    }

    static func of(_ value: Bool?) -> JSONValue {
        value.map(JSONValue.bool) ?? .null
    }

    static func of(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}
