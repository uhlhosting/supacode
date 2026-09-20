import Foundation

private nonisolated let settingsInstallerLogger = SupaLogger("Settings")

nonisolated struct AgentHookSettingsFileInstaller {
  typealias Errors = JSONHookSettingsFile.Errors

  let fileManager: FileManager
  let errors: Errors
  let logWarning: @Sendable (String) -> Void

  init(
    fileManager: FileManager,
    errors: Errors,
    logWarning: @escaping @Sendable (String) -> Void = { settingsInstallerLogger.warning($0) }
  ) {
    self.fileManager = fileManager
    self.errors = errors
    self.logWarning = logWarning
  }

  private var file: JSONHookSettingsFile {
    JSONHookSettingsFile(fileManager: fileManager, errors: errors)
  }

  /// Compare the Supacode-managed command occurrences present in the settings
  /// file against the expected (canonical) occurrences:
  /// - `.installed`     — actual Supacode occurrences == expected, no extras
  /// - `.notInstalled`  — no Supacode-managed commands at all
  /// - `.outdated`      — some present, but occurrences differ (extras, missing,
  ///                      stale variants, duplicates, or a managed command
  ///                      parked under the wrong event/matcher)
  ///
  /// The comparison is the ordered sequence of managed groups per event
  /// (matcher + managed commands, in array order) rather than a command
  /// `Set`. Canonical payloads legitimately reuse one command string in
  /// several slots (e.g. `busy` under both `UserPromptSubmit` and the
  /// catch-all `PreToolUse` group), and hook groups execute in array order —
  /// a reordered or partially deleted slot must read as drift, while a
  /// user-authored group inserted between managed ones must not.
  ///
  /// `additionalOutdatedIfInstalled` runs only when the command set already
  /// matches, against the **same** parsed snapshot (no second disk read). Use
  /// it for non-command payload checks such as Grok's env passthrough map.
  ///
  /// Throws when the file can't be read or parsed: an unreadable file is not
  /// an uninstalled one, and only the caller can decide what to do about it.
  func installState(
    settingsURL: URL,
    hookGroupsByEvent: [String: [JSONValue]],
    additionalOutdatedIfInstalled: (([String: JSONValue]) -> Bool)? = nil
  ) throws -> ComponentInstallState {
    do {
      let settingsObject = try loadSettingsObject(at: settingsURL)
      let expected = Self.expectedCommandOccurrences(from: hookGroupsByEvent)
      guard !expected.isEmpty else { return .notInstalled }
      let actual = Self.installedSupacodeCommands(in: settingsObject)
      if actual.isEmpty { return .notInstalled }
      guard actual == expected else { return .outdated }
      if let additionalOutdatedIfInstalled, additionalOutdatedIfInstalled(settingsObject) {
        return .outdated
      }
      return .installed
    } catch {
      logWarning("Failed to inspect hook settings at \(settingsURL.path): \(error)")
      throw error
    }
  }

  /// The managed content of one hook group, in execution order: the group's
  /// `matcher` (nil when the key is absent) plus its Supacode-managed commands
  /// in array order. `installState` compares the ordered sequence of these
  /// per event, so reordered groups read as drift even when every command is
  /// still present.
  private struct ManagedGroupOccurrence: Hashable {
    let matcher: JSONValue?
    let commands: [String]
  }

  /// Supacode-managed groups under the `hooks` map, kept in array order per
  /// event. A group contributes only its managed commands — user-authored
  /// hooks and fully user-authored groups are skipped, so inserting a custom
  /// group between managed ones is not drift.
  private static func installedSupacodeCommands(
    in settingsObject: [String: JSONValue]
  ) -> [String: [ManagedGroupOccurrence]] {
    guard let hooksValue = settingsObject["hooks"],
      let hooksObject = hooksValue.objectValue
    else { return [:] }
    var occurrences: [String: [ManagedGroupOccurrence]] = [:]
    for (event, value) in hooksObject {
      guard let groups = value.arrayValue else { continue }
      let managed = groups.compactMap { group -> ManagedGroupOccurrence? in
        guard let groupObject = group.objectValue,
          let hooks = groupObject["hooks"]?.arrayValue
        else { return nil }
        let commands = hooks.compactMap { hook -> String? in
          guard let hookObject = hook.objectValue,
            let command = hookObject["command"]?.stringValue,
            AgentHookCommandOwnership.isSupacodeManagedCommand(command)
          else { return nil }
          return command
        }
        guard !commands.isEmpty else { return nil }
        return ManagedGroupOccurrence(matcher: groupObject["matcher"], commands: commands)
      }
      if !managed.isEmpty {
        occurrences[event] = managed
      }
    }
    return occurrences
  }

  private static func expectedCommandOccurrences(
    from hookGroupsByEvent: [String: [JSONValue]]
  ) -> [String: [ManagedGroupOccurrence]] {
    var occurrences: [String: [ManagedGroupOccurrence]] = [:]
    for (event, groups) in hookGroupsByEvent {
      let managed = groups.compactMap { group -> ManagedGroupOccurrence? in
        guard let groupObject = group.objectValue,
          let hooks = groupObject["hooks"]?.arrayValue
        else { return nil }
        let commands = hooks.compactMap { $0.objectValue?["command"]?.stringValue }
        guard !commands.isEmpty else { return nil }
        return ManagedGroupOccurrence(matcher: groupObject["matcher"], commands: commands)
      }
      if !managed.isEmpty {
        occurrences[event] = managed
      }
    }
    return occurrences
  }

  /// Removes every Supacode-managed command (current and legacy) from the
  /// settings file. User-authored hooks are preserved — the trailing
  /// `# supacode-managed-hook` sentinel is the source of truth for
  /// ownership (see `AgentHookCommandOwnership`).
  func uninstall(
    settingsURL: URL,
    hookGroupsByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    _ = try hookGroupsByEvent()  // Eval for parity with `install` errors; we don't use the value.
    var settingsObject = try loadSettingsObject(at: settingsURL)
    // Symmetric with `install`: refuse to overwrite a non-object `hooks`
    // value (would silently destroy user data we don't own).
    if let hooksValue = settingsObject["hooks"], hooksValue.objectValue == nil {
      throw errors.invalidHooksObject()
    }
    let hooksObject = settingsObject["hooks"]?.objectValue ?? [:]
    let pruned = try pruneAllSupacodeCommands(from: hooksObject)
    settingsObject["hooks"] = .object(pruned)
    try writeSettings(settingsObject, to: settingsURL)
  }

  /// `install = uninstall + append`: strip every Supacode-managed entry from
  /// the existing hook map (current + legacy + pre-collapse splits), then
  /// append the canonical groups 1:1. Done in a single read-modify-write so
  /// a crash mid-update can't leave the file half-pruned.
  func install(
    settingsURL: URL,
    hookGroupsByEvent: @autoclosure () throws -> [String: [JSONValue]]
  ) throws {
    let canonicalGroups = try hookGroupsByEvent()
    var settingsObject = try loadSettingsObject(at: settingsURL)
    if let hooksValue = settingsObject["hooks"], hooksValue.objectValue == nil {
      throw errors.invalidHooksObject()
    }
    let existing = settingsObject["hooks"]?.objectValue ?? [:]
    var pruned = try pruneAllSupacodeCommands(from: existing)
    for (event, groups) in canonicalGroups {
      let existingGroups = pruned[event]?.arrayValue ?? []
      pruned[event] = .array(existingGroups + groups)
    }
    settingsObject["hooks"] = .object(pruned)
    try writeSettings(settingsObject, to: settingsURL)
  }

  /// Builds a fresh hooks map with every Supacode-managed command
  /// stripped. Builds a new dict instead of mutating while iterating, to
  /// guarantee no event is silently skipped during the prune.
  private func pruneAllSupacodeCommands(
    from hooksObject: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for (event, value) in hooksObject {
      guard let groups = value.arrayValue else {
        throw errors.invalidEventHooks(event)
      }
      let filtered = groups.compactMap { stripAllSupacodeCommands(from: $0) }
      if !filtered.isEmpty {
        result[event] = .array(filtered)
      }
    }
    return result
  }

  private func writeSettings(_ object: [String: JSONValue], to url: URL) throws {
    try file.write(object, to: url)
  }

  private func loadSettingsObject(at url: URL) throws -> [String: JSONValue] {
    try file.load(at: url)
  }

  /// Strip every Supacode-managed command from the group. User-authored
  /// hooks (no `# supacode-managed-hook` sentinel) survive untouched.
  private func stripAllSupacodeCommands(from group: JSONValue) -> JSONValue? {
    guard var groupObject = group.objectValue else { return group }
    guard let hooksValue = groupObject["hooks"] else { return group }
    guard let hooks = hooksValue.arrayValue else { return group }
    let filteredHooks = hooks.filter { hook in
      guard let hookObject = hook.objectValue,
        let command = hookObject["command"]?.stringValue
      else { return true }
      return !AgentHookCommandOwnership.isSupacodeManagedCommand(command)
    }
    guard !filteredHooks.isEmpty else { return nil }
    groupObject["hooks"] = .array(filteredHooks)
    return .object(groupObject)
  }
}
