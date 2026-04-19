import Foundation

/// Single source of truth for resolving file paths against session workspace.
///
/// Rules:
/// Absolute paths (starts with "/") pass through unchanged.
/// Relative paths resolve against workspace if available.
/// Empty path with workspace defaults to workspace root.
/// Empty path without workspace → error.
/// Relative path without workspace → error.
public enum WorkspacePathResolver {

 public enum Result {
 case resolved(String)
 case error(String)
 }

 public static func resolve(_ path: String, workspace: URL?) -> Result {
 if path.hasPrefix("/") {
 return .resolved(path)
 }
 if path.isEmpty, let workspace {
 return .resolved(workspace.path)
 }
 if let workspace {
 return .resolved(workspace.appendingPathComponent(path).path)
 }
 if path.isEmpty {
 return .error("No path specified and no workspace set for this session")
 }
 return .error("Relative path '\(path)' requires a workspace. Create this session with a folder, or use an absolute path.")
 }
}
