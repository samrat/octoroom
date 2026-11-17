import Foundation

/// A JSON value: what Phoenix channel payloads are made of.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { object[key] } else { nil }
  }

  public var stringValue: String? {
    if case .string(let s) = self { s } else { nil }
  }

  public var boolValue: Bool? {
    if case .bool(let b) = self { b } else { nil }
  }

  public var doubleValue: Double? {
    if case .number(let n) = self { n } else { nil }
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let a) = self { a } else { nil }
  }

  public var isNull: Bool { self == .null }

  /// Encodes any `Encodable` as a JSON value.
  public init<T: Encodable>(encoding value: T) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  /// Decodes this value as `T`.
  public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let b = try? container.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? container.decode(Double.self) {
      self = .number(n)
    } else if let s = try? container.decode(String.self) {
      self = .string(s)
    } else if let a = try? container.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let b): try container.encode(b)
    case .number(let n): try container.encode(n)
    case .string(let s): try container.encode(s)
    case .array(let a): try container.encode(a)
    case .object(let o): try container.encode(o)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}
