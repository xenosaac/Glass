import Foundation

// MARK: - JSON-RPC 2.0 Message Types

/// JSON-RPC 2.0 request envelope
public struct JSONRPCRequest: Codable, Sendable {
 public let jsonrpc: String
 public let id: String?
 public let method: String
 public let params: [String: AnyCodable]?

 public init(method: String, params: [String: AnyCodable]? = nil, id: String? = UUID().uuidString) {
 self.jsonrpc = "2.0"
 self.id = id
 self.method = method
 self.params = params
 }

 public static func notification(method: String, params: [String: AnyCodable]? = nil) -> JSONRPCRequest {
 JSONRPCRequest(method: method, params: params, id: nil)
 }

 enum CodingKeys: String, CodingKey {
 case jsonrpc, id, method, params
 }

 public init(from decoder: Decoder) throws {
 let container = try decoder.container(keyedBy: CodingKeys.self)
 jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
 id = try container.decodeIfPresent(String.self, forKey: .id)
 method = try container.decode(String.self, forKey: .method)
 params = try container.decodeIfPresent([String: AnyCodable].self, forKey: .params)
 }

 public func encode(to encoder: Encoder) throws {
 var container = encoder.container(keyedBy: CodingKeys.self)
 try container.encode(jsonrpc, forKey: .jsonrpc)
 if let id {
 try container.encode(id, forKey: .id)
 }
 try container.encode(method, forKey: .method)
 try container.encodeIfPresent(params, forKey: .params)
 }
}

/// JSON-RPC 2.0 response envelope
public struct JSONRPCResponse<T: Codable>: Codable {
 public let jsonrpc: String
 public let id: AnyCodable?
 public let result: T?
 public let error: JSONRPCError?
}

/// JSON-RPC 2.0 error object
public struct JSONRPCError: Codable, Error, Sendable {
 public let code: Int
 public let message: String
 public let data: AnyCodable?
}

// MARK: - MCP Tool Types

/// MCP tool definition from tools/list response
public struct MCPToolDefinition: Codable, Sendable {
 public let name: String
 public let description: String?
 public let inputSchema: MCPInputSchema

 // Optional MCP 2024-11 annotations (if provided by server)
 public let annotations: MCPToolAnnotations?

 public init(name: String, description: String?, inputSchema: MCPInputSchema, annotations: MCPToolAnnotations? = nil) {
 self.name = name
 self.description = description
 self.inputSchema = inputSchema
 self.annotations = annotations
 }
}

/// MCP tool annotations for safety/behavior hints
public struct MCPToolAnnotations: Codable, Sendable {
 /// Tool does not modify external state
 public let readOnlyHint: Bool?
 /// Tool may cause irreversible changes
 public let destructiveHint: Bool?
 /// Calling multiple times with same args gives same result
 public let idempotentHint: Bool?
 /// Tool may take a long time to run
 public let longRunningHint: Bool?
 /// Human-readable summary of side effects
 public let sideEffectDescription: String?

 enum CodingKeys: String, CodingKey {
 case readOnlyHint = "readOnly"
 case destructiveHint = "destructive"
 case idempotentHint = "idempotent"
 case longRunningHint = "longRunning"
 case sideEffectDescription = "sideEffects"
 }
}

/// JSON Schema for tool input
public struct MCPInputSchema: Codable, Sendable {
 public let type: String
 public let properties: [String: AnyCodable]?
 public let required: [String]?

 public init(type: String = "object", properties: [String: AnyCodable]? = nil, required: [String]? = nil) {
 self.type = type
 self.properties = properties
 self.required = required
 }

 /// Convert to JSON string for RelayTool.inputSchema
 public func toJSONString() -> String {
 var dict: [String: Any] = ["type": type]
 if let props = properties {
 dict["properties"] = props.mapValues { $0.value }
 }
 if let req = required {
 dict["required"] = req
 }
 guard let data = try? JSONSerialization.data(withJSONObject: dict),
 let str = String(data: data, encoding: .utf8) else {
 return #"{"type":"object"}"#
 }
 return str
 }
}

/// MCP tools/list response
public struct MCPToolsListResult: Codable, Sendable {
 public let tools: [MCPToolDefinition]
}

/// MCP tools/call response
public struct MCPToolCallResult: Codable, Sendable {
 public let content: [MCPContentBlock]
 public let isError: Bool?

 public init(content: [MCPContentBlock], isError: Bool? = nil) {
 self.content = content
 self.isError = isError
 }
}

/// Content block in tool call result
public struct MCPContentBlock: Codable, Sendable {
 public let type: String // "text", "image", "resource"
 public let text: String?
 public let data: String? // base64 for images
 public let mimeType: String?

 public init(type: String = "text", text: String? = nil, data: String? = nil, mimeType: String? = nil) {
 self.type = type
 self.text = text
 self.data = data
 self.mimeType = mimeType
 }
}

// MARK: - MCP Resource Types

/// MCP resource definition from resources/list
public struct MCPResourceDefinition: Codable, Sendable {
 public let uri: String
 public let name: String?
 public let description: String?
 public let mimeType: String?
}

/// MCP resources/list response
public struct MCPResourcesListResult: Codable, Sendable {
 public let resources: [MCPResourceDefinition]
}

// MARK: - MCP Lifecycle Types

public struct MCPImplementationInfo: Codable, Sendable {
 public let name: String
 public let version: String?
 public let title: String?
 public let description: String?
}

public struct MCPInitializeResult: Codable, Sendable {
 public let protocolVersion: String
 public let capabilities: [String: AnyCodable]?
 public let serverInfo: MCPImplementationInfo
 public let instructions: String?
}

// MARK: - AnyCodable (Type-Erased Codable)

/// Type-erased Codable wrapper for dynamic JSON values.
///
/// Backed by a recursive JSON enum so the type is genuinely `Sendable` under
/// Swift 6, instead of storing an unconstrained `Any`.
public enum AnyCodable: Codable, Sendable {
 case null
 case bool(Bool)
 case int(Int)
 case double(Double)
 case string(String)
 case array([AnyCodable])
 case dictionary([String: AnyCodable])

 public var value: Any {
 switch self {
 case .null:
 return NSNull()
 case .bool(let bool):
 return bool
 case .int(let int):
 return int
 case .double(let double):
 return double
 case .string(let string):
 return string
 case .array(let array):
 return array.map(\.value)
 case .dictionary(let dict):
 return dict.mapValues(\.value)
 }
 }

 public init(_ value: Any) {
 switch value {
 case is NSNull:
 self = .null
 case let bool as Bool:
 self = .bool(bool)
 case let int as Int:
 self = .int(int)
 case let double as Double:
 self = .double(double)
 case let string as String:
 self = .string(string)
 case let array as [Any]:
 self = .array(array.map(AnyCodable.init))
 case let dict as [String: Any]:
 self = .dictionary(dict.mapValues(AnyCodable.init))
 case let float as Float:
 self = .double(Double(float))
 case let number as NSNumber:
 if CFGetTypeID(number) == CFBooleanGetTypeID() {
 self = .bool(number.boolValue)
 } else if number.doubleValue.rounded(.towardZero) == number.doubleValue {
 self = .int(number.intValue)
 } else {
 self = .double(number.doubleValue)
 }
 default:
 self = .string(String(describing: value))
 }
 }

 public init(from decoder: Decoder) throws {
 let container = try decoder.singleValueContainer()

 if container.decodeNil() {
 self = .null
 } else if let bool = try? container.decode(Bool.self) {
 self = .bool(bool)
 } else if let int = try? container.decode(Int.self) {
 self = .int(int)
 } else if let double = try? container.decode(Double.self) {
 self = .double(double)
 } else if let string = try? container.decode(String.self) {
 self = .string(string)
 } else if let array = try? container.decode([AnyCodable].self) {
 self = .array(array)
 } else if let dict = try? container.decode([String: AnyCodable].self) {
 self = .dictionary(dict)
 } else {
 throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
 }
 }

 public func encode(to encoder: Encoder) throws {
 var container = encoder.singleValueContainer()

 switch self {
 case .null:
 try container.encodeNil()
 case .bool(let bool):
 try container.encode(bool)
 case .int(let int):
 try container.encode(int)
 case .double(let double):
 try container.encode(double)
 case .string(let string):
 try container.encode(string)
 case .array(let array):
 try container.encode(array)
 case .dictionary(let dict):
 try container.encode(dict)
 }
 }
}
