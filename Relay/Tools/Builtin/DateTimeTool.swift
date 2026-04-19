import Foundation

/// Returns the current date, time, weekday, and timezone.
/// Zero dependencies — no network, no permissions. Useful for verifying the tool dispatch loop works.
public struct DateTimeTool: RelayTool, Sendable {
 public var name: String { "get_current_datetime" }
 public var description: String { "Returns the current date, time, weekday, and timezone." }
 public var inputSchema: ToolInputSchema {
 ToolInputSchema(json: #"{"type":"object","properties":{}}"#)
 }
 public var isConcurrencySafe: Bool { true }
 public var isReadOnly: Bool { true }
 public var isDestructive: Bool { false }

 public func call(input: ToolInput, context: ToolCallContext) async throws -> ToolResult {
 let now = Date()
 let formatter = DateFormatter()

 formatter.dateFormat = "yyyy-MM-dd"
 let date = formatter.string(from: now)

 formatter.dateFormat = "HH:mm:ss"
 let time = formatter.string(from: now)

 formatter.dateFormat = "EEEE"
 let weekday = formatter.string(from: now)

 let tz = TimeZone.current
 let iso = ISO8601DateFormatter().string(from: now)

 let output = """
 Date: \(date)
 Time: \(time)
 Weekday: \(weekday)
 Timezone: \(tz.identifier) (UTC\(tz.secondsFromGMT() >= 0 ? "+" : "")\(tz.secondsFromGMT() / 3600))
 ISO8601: \(iso)
 """

 return ToolResult(toolUseId: "", output: output)
 }

 public func policyDescriptor(input: ToolInput, context: ToolCallContext) async -> ToolPolicyDescriptor {
 .readOnly(domain: .builtin, operation: .read, summary: description)
 }
}
