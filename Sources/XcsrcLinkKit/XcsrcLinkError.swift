import Foundation

/// Errors thrown by ``Linker``. `description` is a plain sentence without command-line
/// hints, so tools built on the library can add their own.
public enum XcsrcLinkError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The input path doesn't exist.
  case notFound(path: String)
  /// The source folder doesn't exist or isn't a folder.
  case sourceFolderNotFound(path: String)
  /// The input has no static library, dSYM or DWARF with source paths.
  case noDebugInfo(input: String)
  /// ``LinkOptions`` has neither `sourceRoot` nor `explicitMappings`.
  case missingSourceOrMappings
  /// None of the recorded source files matched a file under `sourceRoot`.
  case noMatchingSources(input: String, recordedFiles: Int, sourceRoot: String)
  /// A scheme given as an `.xcscheme` path doesn't exist.
  case schemeNotFound(path: String)
  /// A scheme given as an `.xcscheme` path isn't inside an `.xcodeproj` or
  /// `.xcworkspace`.
  case schemeOutsideProject(path: String)
  /// Scheme names that the project at `projectDir` doesn't have.
  case unknownSchemes(names: [String], projectDir: String, available: [String])
  /// Patching would invalidate this xcframework's signature; set `stripSignature` to
  /// allow it.
  case signedXCFramework(path: String)
  /// The `symlink` strategy found a symlink pointing somewhere else at a build path.
  case symlinkConflict(path: String, destination: String)
  /// The `symlink` strategy found a real file or folder at a build path.
  case pathExists(path: String)
  /// The `symlink` strategy couldn't create the build path, usually for lack of
  /// permissions. `parent` is the first folder that has to be made writable.
  case cannotCreateSymlink(path: String, parent: String, reason: String)
  /// The `patch` strategy can't rewrite a relative build path in place.
  case relativeBuildPath(PathMapping)
  /// The `patch` strategy keeps string lengths, and this local path is longer than the
  /// build path.
  case replacementTooLong(PathMapping, extraBytes: Int)
  /// A file couldn't be read.
  case unreadable(path: String)
  /// No link has this name.
  case noLink(name: String)
  /// An external tool (e.g. `dwarfdump`) failed.
  case toolFailed(command: String, status: Int32, message: String)

  public var description: String {
    switch self {
    case let .notFound(p):
      "not found: \(p)"
    case let .sourceFolderNotFound(p):
      "source folder not found: \(p)"
    case let .noDebugInfo(input):
      "no debug info with source paths found in \(input). Build the library with -g (DEBUG_INFORMATION_FORMAT) and ship .a files or dSYMs."
    case .missingSourceOrMappings:
      "no source folder or path mappings given"
    case let .noMatchingSources(_, count, root):
      "couldn't match any of the \(count) recorded source files to files under \(root). Is this the right checkout?"
    case let .schemeNotFound(p):
      "scheme not found: \(p)"
    case let .schemeOutsideProject(p):
      "\(p) is not inside an .xcodeproj or .xcworkspace"
    case let .unknownSchemes(names, dir, available):
      "no scheme named \(names.joined(separator: ", ")) in \(dir). Found: \(available.joined(separator: ", "))"
    case let .signedXCFramework(p):
      "\(p) is code signed and patching would invalidate its signature, so Xcode would reject it."
    case let .symlinkConflict(p, dest):
      "\(p) is already a symlink to \(dest). Remove it first."
    case let .pathExists(p):
      "\(p) already exists and is not a symlink; refusing to replace it."
    case let .cannotCreateSymlink(p, _, reason):
      "couldn't create \(p): \(reason)"
    case let .relativeBuildPath(m):
      "can't patch relative build path '\(m.from)' in place; use the lldbinit strategy instead"
    case let .replacementTooLong(m, extra):
      """
      can't patch '\(m.from)' in place: the local path '\(m.to)' is \(extra) bytes longer than the build path.
        Binary patching keeps every string the same length. Either use the lldbinit strategy
        (no binary changes), or put your checkout at a path no longer than the build path.
      """
    case let .unreadable(p):
      "can't read \(p)"
    case let .noLink(name):
      "no link named '\(name)'"
    case let .toolFailed(cmd, _, message):
      "\(cmd) failed: \(message)"
    }
  }
}
