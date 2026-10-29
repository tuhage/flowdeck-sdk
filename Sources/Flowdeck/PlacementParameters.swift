import Foundation

/// Placement-scoped values. Accessors use the supplied default for missing keys or type mismatches.
public struct PlacementParameters: Codable, Sendable, Equatable {
    private let values: [String: JSONValue]

    public init() { values = [:] }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([String: JSONValue].self)
        for value in values.values {
            switch value {
            case .bool, .string: break
            case .number(let number) where number.isFinite: break
            default:
                throw DecodingError.dataCorruptedError(in: container,
                    debugDescription: "Placement parameters must be strings, finite numbers or booleans.")
            }
        }
        self.values = values
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard case .bool(let value) = values[key] else { return defaultValue }
        return value
    }

    public func string(_ key: String, default defaultValue: String) -> String {
        guard case .string(let value) = values[key] else { return defaultValue }
        return value
    }

    public func number(_ key: String, default defaultValue: Double) -> Double {
        guard case .number(let value) = values[key] else { return defaultValue }
        return value
    }
}
