import Foundation

/// Something ``Linker`` noticed but didn't stop for. `description` is a plain sentence
/// without command-line hints, so tools built on the library can add their own.
public enum LinkWarning: Equatable, Sendable, CustomStringConvertible {
  /// Something skipped while looking for binaries, e.g. a dynamic framework without a
  /// dSYM.
  case note(String)
  /// Recorded files that matched several local files equally well, so none was used.
  case ambiguousMatches(count: Int, example: String)
  /// Recorded files with no match under the source folder.
  case unmatchedFiles(count: Int, total: Int, sourceRoot: String, example: String)
  /// No saved Xcode scheme was found at or above the lldbinit file.
  case noSchemeFound(lldbinit: String)
  /// A scheme without a Run action, so there's no LLDB Init File to set.
  case schemeWithoutRunAction(name: String)
  /// A scheme that already uses another LLDB Init File; it's left alone.
  case schemeUsesOtherInitFile(name: String, file: String, lldbinit: String)
  /// On unlink, a scheme no longer uses the value xcsrclink wrote; it's left alone.
  case schemeChangedSinceLinked(name: String, value: String)
  /// On unlink, a scheme file couldn't be rewritten.
  case schemeNotUpdated(name: String, path: String)
  /// Other dSYMs with the same UUID as a patched one still have the build machine's
  /// paths, and lldb may load one of them. See ``Linker/dSYMCopies(of:)``.
  case unpatchedDSYMCopies(input: String, copies: [String])
  /// The `symlink` strategy can't create a symlink at a relative build path.
  case relativeSymlinkSkipped(path: String)
  /// On unlink, a patched file's backup is gone, so the file stays patched.
  case backupMissing(path: String)
  /// On unlink, a patched file changed since it was patched (an updated library?), so it
  /// isn't restored unless forced.
  case patchedFileChanged(path: String)

  public var description: String {
    switch self {
    case let .note(text):
      text
    case let .ambiguousMatches(count, example):
      "\(count) file(s) matched several local files equally well and were skipped, "
        + "e.g. \(example). Give explicit mappings for them."
    case let .unmatchedFiles(count, total, root, example):
      "\(count) of \(total) source file(s) have no match under \(root), e.g. \(example)"
    case let .noSchemeFound(lldbinit):
      "no saved Xcode scheme found at or above \(PathUtil.tildeAbbreviated(lldbinit)), "
        + "so no scheme was changed. Pass the .xcscheme path, or set Edit Scheme › Run › Info "
        + "› LLDB Init File to this file yourself."
    case let .schemeWithoutRunAction(name):
      "scheme '\(name)' has no Run action, skipping it"
    case let .schemeUsesOtherInitFile(name, file, lldbinit):
      "scheme '\(name)' already uses LLDB Init File \(file), leaving it. "
        + "Add `command source \(PathUtil.tildeAbbreviated(lldbinit))` to that file instead."
    case let .schemeChangedSinceLinked(name, value):
      "scheme '\(name)' no longer uses \(value), leaving it"
    case let .schemeNotUpdated(name, path):
      "couldn't update scheme '\(name)' at \(path)"
    case let .unpatchedDSYMCopies(_, copies):
      """
      Other copies of the patched dSYM still have the build machine's paths. lldb finds \
      dSYMs by UUID and may load one of them instead. Rebuild the project each belongs to \
      (Xcode copies the dSYM again), or delete it:
      """ + copies.map { "\n  \(PathUtil.tildeAbbreviated($0))" }.joined()
    case let .relativeSymlinkSkipped(path):
      "skipping symlink for relative build path '\(path)'"
    case let .backupMissing(path):
      "backup missing for \(path), leaving it patched"
    case let .patchedFileChanged(path):
      "\(path) changed since it was patched (updated library?), not restoring it. "
        + "Unlink with force to restore it anyway."
    }
  }
}
