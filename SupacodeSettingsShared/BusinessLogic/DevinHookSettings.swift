import Foundation

nonisolated enum DevinHookSettings {
  /// Canonical hook map for Devin. One composite command per (event,
  /// matcher) slot keeps the prune-and-replace cycle idempotent.
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: DevinHooksPayload(),
      invalidConfiguration: DevinHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum DevinHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Hook payload.

// Devin reads `hooks` from `~/.config/devin/config.json` in Claude's events
// shape, with two deltas: there is no `Notification` event, and hook matchers
// see snake_case tool names (`ask_user_question`, not `AskUserQuestion`). The
// busy/idle/awaitingInput mapping otherwise mirrors `ClaudeHooksPayload`:
// `PermissionRequest` stands in for Claude's permission `Notification`, and
// `Stop` carries `last_assistant_message`, so the stdin-sourced notify lands
// the turn's final response like Claude's idle branch. `PostCompaction` is
// intentionally not mapped: it fires after compaction finishes, so it can't
// drive the compacting badge.
private nonisolated struct DevinHooksPayload: Encodable {
  static let awaitingInputToolMatcher = "ask_user_question|exit_plan_mode"

  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .devin)
  private static let idle = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: false, agent: .devin)
  private static let awaitingInput = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: false, agent: .devin)
  private static let permissionRequest = AgentHookSettingsCommand.devinPermissionRequestCommand(
    agent: .devin)
  private static let idleAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.idle], forwardStdinAsNotification: true, agent: .devin)
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .devin)
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .devin)

  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: Self.sessionStart, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)]),
      // Array-order: matched-by-name fires AFTER matcher-"", so awaiting wins.
      .init(
        matcher: Self.awaitingInputToolMatcher,
        hooks: [.init(command: Self.awaitingInput, timeout: AgentHookSettingsCommand.timeoutSeconds)]
      ),
    ],
    "PermissionRequest": [
      .init(
        matcher: "",
        hooks: [.init(command: Self.permissionRequest, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "PostToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.idle, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "Stop": [
      .init(
        matcher: "", hooks: [.init(command: Self.idleAndNotify, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "SessionEnd": [
      .init(
        matcher: "", hooks: [.init(command: Self.sessionEndAndIdle, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
  ]
}
