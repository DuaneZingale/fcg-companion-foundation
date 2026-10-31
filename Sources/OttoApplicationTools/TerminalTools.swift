import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools

public struct TerminalOpenInput: Codable, Sendable {
  public var x: Double
  public var y: Double
  public var shell: String?

  public init(x: Double, y: Double, shell: String? = nil) {
    self.x = x
    self.y = y
    self.shell = shell
  }
}

public struct TerminalRunInput: Codable, Sendable {
  public var command: String
  public var x: Double
  public var y: Double
  public var shell: String?

  public init(command: String, x: Double, y: Double, shell: String? = nil) {
    self.command = command
    self.x = x
    self.y = y
    self.shell = shell
  }
}

public struct TerminalIDInput: Codable, Sendable {
  public var terminalID: UUID
  public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct TerminalWaitInput: Codable, Sendable {
  public var terminalID: UUID
  public var timeoutMilliseconds: Int?

  public init(terminalID: UUID, timeoutMilliseconds: Int? = nil) {
    self.terminalID = terminalID
    self.timeoutMilliseconds = timeoutMilliseconds
  }
}

public struct TerminalInputInput: Codable, Sendable {
  public var terminalID: UUID
  public var text: String

  public init(terminalID: UUID, text: String) {
    self.terminalID = terminalID
    self.text = text
  }
}

public struct TerminalBytesInput: Codable, Sendable {
  public var terminalID: UUID
  public var data: Data

  public init(terminalID: UUID, data: Data) {
    self.terminalID = terminalID
    self.data = data
  }
}

public struct TerminalResizeInput: Codable, Sendable {
  public var terminalID: UUID
  public var columns: UInt16
  public var rows: UInt16

  public init(terminalID: UUID, columns: UInt16, rows: UInt16) {
    self.terminalID = terminalID
    self.columns = columns
    self.rows = rows
  }
}

public struct TerminalOutput: Codable, Sendable, Equatable {
  public var terminalID: UUID
  public var state: AgentLifecycleState
  public var exitCode: Int32?
  public var boundedOutput: String
  /// True when the command has gone quiet at a prompt and is waiting for the person to answer in
  /// the terminal. Otto shows them a "Waiting for you" banner; tell them where to look.
  public var waitingForUser: Bool?
  /// The prompt line the command is waiting on, when `waitingForUser` is true.
  public var prompt: String?
  /// The terminal's title in Otto, set when it is started.
  public var title: String?
  /// Where the person finds this terminal in Otto, set when it is started.
  public var whereToFindIt: String?
}

public struct TerminalOpenTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "terminal.open",
    description:
      "Starts a supervised interactive local shell. Otto makes it available in the work panel on "
      + "the right of the conversation that opened it (a tab titled \"Terminal\"). "
      + "The panel stays closed until the person opens it. They can click into the terminal and type. Use terminal.run "
      + "instead when you have a specific command to run.",
    inputSchema: .objectSchema(
      properties: [
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
        "shell": .stringSchema(description: "Optional absolute shell path; defaults to /bin/zsh"),
      ],
      required: ["x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite, .terminalControl],
    riskLevel: .consequential
  )

  private let store: CanvasStore
  private let supervisor: AgentSupervisor
  private let workspacePath: String

  public init(store: CanvasStore, supervisor: AgentSupervisor, workspacePath: String) {
    self.store = store
    self.supervisor = supervisor
    self.workspacePath = workspacePath
  }

  public func call(_ input: TerminalOpenInput, context: ToolContext) async throws -> TerminalOutput
  {
    try await launch(
      store: store,
      supervisor: supervisor,
      workspacePath: workspacePath,
      point: WorldPoint(x: input.x, y: input.y),
      shell: input.shell,
      command: nil,
      context: context
    )
  }
}

public struct TerminalRunTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "terminal.run",
    description:
      "Asks for approval of the full shell command in this chat, then starts it in an Otto-supervised terminal and returns immediately. Otto makes it available in "
      + "the work panel on the right of this chat, in a tab named after the command (the result's "
      + "`title`, e.g. \"Setup script\"). The panel stays closed until the person opens it. "
      + "Use it for interactive steps the person must do themselves (pressing a key, pasting a "
      + "token or password, signing in): the person types straight into that terminal, and "
      + "hidden input such as passwords is never shown to you. When a step needs them, tell them "
      + "exactly where to look, e.g. \"click into the Setup script terminal in the panel on the "
      + "right and follow the prompts\". Otto marks the terminal \"Waiting for you\" when it "
      + "goes quiet at a prompt, and terminal.wait returns early with waitingForUser=true. "
      + "For long-running commands, keep terminalID and call terminal.wait instead of using a "
      + "provider's own background shell feature.",
    inputSchema: .objectSchema(
      properties: [
        "command": .stringSchema(description: "Shell command to run"),
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
        "shell": .stringSchema(description: "Optional absolute shell path; defaults to /bin/zsh"),
      ],
      required: ["command", "x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite, .terminalControl],
    riskLevel: .consequential,
    requiresConfirmation: true
  )

  private let store: CanvasStore
  private let supervisor: AgentSupervisor
  private let workspacePath: String

  public init(store: CanvasStore, supervisor: AgentSupervisor, workspacePath: String) {
    self.store = store
    self.supervisor = supervisor
    self.workspacePath = workspacePath
  }

  public func call(_ input: TerminalRunInput, context: ToolContext) async throws -> TerminalOutput {
    guard !input.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ToolRegistryError.invalidInput("A terminal command is required")
    }
    let output = try await launch(
      store: store,
      supervisor: supervisor,
      workspacePath: workspacePath,
      point: WorldPoint(x: input.x, y: input.y),
      shell: input.shell,
      command: input.command,
      context: context
    )
    if context.source == .agent, let parentID = context.sourceNodeID {
      await supervisor.registerDelegatedChild(
        parentID: parentID, childID: output.terminalID, name: output.title ?? input.command,
        kind: "command")
    }
    return output
  }
}

public struct TerminalSendInputTool: OttoTool {
  public static let definition = terminalControlDefinition(
    name: "terminal.send_input",
    description: "Sends a line of input to a running terminal process."
  )
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: TerminalInputInput, context: ToolContext) async throws -> TerminalOutput
  {
    try await supervisor.sendInput(agentID: input.terminalID, text: input.text)
    return try await terminalOutput(id: input.terminalID, supervisor: supervisor)
  }
}

public struct TerminalReadOutputTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "terminal.read_output",
    description: "Asks for approval, then reads bounded output and process state from a terminal node.",
    inputSchema: terminalIDSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read,
    requiresConfirmation: true
  )
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: TerminalIDInput, context: ToolContext) async throws -> TerminalOutput {
    try await terminalOutput(id: input.terminalID, supervisor: supervisor)
  }
}

public struct TerminalWaitTool: OttoTool {
  public static let maximumTimeoutMilliseconds = 30_000
  public static let definition = ToolDefinition(
    name: "terminal.wait",
    description:
      "Asks for approval to read output, then waits without polling for an Otto-supervised terminal command to finish. Returns "
      + "immediately when it is already finished, early with waitingForUser=true when the command "
      + "starts waiting for the person to answer a prompt in the terminal (tell them where it is "
      + "and what to do, then wait again), or with its current state and bounded output when the "
      + "timeout expires; call again while state is working or waiting_user.",
    inputSchema: .objectSchema(
      properties: [
        "terminalID": .stringSchema(description: "Stable terminal node UUID from terminal.run"),
        "timeoutMilliseconds": .object([
          "type": .string("integer"),
          "minimum": .number(1),
          "maximum": .number(Double(maximumTimeoutMilliseconds)),
          "description": .string("How long to wait; defaults to 30000 milliseconds"),
        ]),
      ],
      required: ["terminalID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.terminalControl],
    riskLevel: .read,
    requiresConfirmation: true
  )

  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: TerminalWaitInput, context: ToolContext) async throws -> TerminalOutput
  {
    let timeout = input.timeoutMilliseconds ?? Self.maximumTimeoutMilliseconds
    guard (1...Self.maximumTimeoutMilliseconds).contains(timeout) else {
      throw ToolRegistryError.invalidInput(
        "Terminal wait timeout must be between 1 and \(Self.maximumTimeoutMilliseconds) milliseconds"
      )
    }

    // Capture the sequence before reading state so a completion racing with the snapshot is
    // replayed by EventWaitTool instead of being lost between two independent operations.
    var afterSequence = supervisor.eventBus.latestSequence
    let initial = try await terminalOutput(id: input.terminalID, supervisor: supervisor)
    // Already waiting on the person is not news: wait for it to move on (or to ask again) so an
    // agent that waits in a loop does not spin while the person is still typing.
    if terminalHasFinished(initial) { return initial }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(timeout))
    while true {
      let remaining = clock.now.duration(to: deadline)
      let remainingMilliseconds =
        Int(remaining.components.seconds * 1_000)
        + Int(remaining.components.attoseconds / 1_000_000_000_000_000)
      guard remainingMilliseconds >= 1 else { break }
      do {
        let event = try await EventWaitTool(bus: supervisor.eventBus).call(
          EventWaitInput(
            types: [.agentRunCompleted, .agentRunFailed, .agentExited, .agentStatusChanged],
            nodeID: input.terminalID,
            afterSequence: afterSequence,
            timeoutMilliseconds: min(remainingMilliseconds, Self.maximumTimeoutMilliseconds)
          ),
          context: context
        )
        afterSequence = event.sequence
        // A status change is only an answer when the command now needs the person; any other
        // transition (back to working) keeps waiting for completion.
        if event.type != .agentStatusChanged || event.state == .waitingUser { break }
      } catch EventWaitError.timedOut {
        // A timeout is an observation point, not a failed command. Returning the current state
        // lets every provider safely do other work or wait again without a polling shell loop.
        break
      }
    }
    return try await terminalOutput(id: input.terminalID, supervisor: supervisor)
  }
}

public struct TerminalSendBytesTool: OttoTool {
  public static let definition = terminalControlDefinition(
    name: "terminal.send_bytes",
    description:
      "Forwards bounded keyboard or mouse input bytes from the embedded terminal renderer."
  )
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: TerminalBytesInput, context: ToolContext) async throws -> TerminalOutput
  {
    guard input.data.count <= 65_536 else {
      throw ToolRegistryError.invalidInput("Terminal input is limited to 65536 bytes")
    }
    try await supervisor.sendBytes(agentID: input.terminalID, data: input.data)
    return try await terminalOutput(id: input.terminalID, supervisor: supervisor)
  }
}

public struct TerminalResizeTool: OttoTool {
  public static let definition = terminalControlDefinition(
    name: "terminal.resize",
    description: "Resizes the supervised PTY to match its embedded terminal renderer."
  )
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: TerminalResizeInput, context: ToolContext) async throws
    -> TerminalOutput
  {
    guard (20...500).contains(input.columns), (4...300).contains(input.rows) else {
      throw ToolRegistryError.invalidInput("Terminal size is outside the supported range")
    }
    try await supervisor.resize(
      agentID: input.terminalID,
      columns: input.columns,
      rows: input.rows
    )
    return try await terminalOutput(id: input.terminalID, supervisor: supervisor)
  }
}

public struct TerminalStopProcessTool: OttoTool {
  public static let definition = terminalControlDefinition(
    name: "terminal.stop_process",
    description: "Stops a running terminal process."
  )
  private let supervisor: AgentSupervisor
  public init(supervisor: AgentSupervisor) { self.supervisor = supervisor }

  public func call(_ input: TerminalIDInput, context: ToolContext) async throws -> TerminalOutput {
    try await supervisor.stop(agentID: input.terminalID)
    return try await terminalOutput(id: input.terminalID, supervisor: supervisor)
  }
}

private func launch(
  store: CanvasStore,
  supervisor: AgentSupervisor,
  workspacePath: String,
  point: WorldPoint,
  shell: String?,
  command: String?,
  context: ToolContext
) async throws -> TerminalOutput {
  let executable = try validatedShell(shell ?? "/bin/zsh")
  let canvasID = try await store.resolvedCanvasID(for: context)
  // An agent's terminal belongs to its conversation, so Chat opens it in that work panel. It
  // must not take the conversation's focus, which createNode guarantees for owned nodes.
  let ownerAgentID = context.source == .agent ? context.sourceNodeID : nil
  let receipt = try await store.dispatch(
    .createNode(kind: .terminal, at: point, parentAgentID: ownerAgentID),
    context: context
  )
  guard let nodeID = receipt.affectedNodeIDs.first else {
    throw ToolRegistryError.invalidInput("Terminal node creation produced no node")
  }
  _ = try await store.dispatch(
    .setNodeContent(id: nodeID, content: .terminal(shell: executable)),
    context: context
  )
  let title =
    command.map { TerminalInputWaitDetector.friendlyTitle(forCommand: $0) } ?? "Terminal"
  if let command {
    _ = try await store.dispatch(.renameNode(id: nodeID, name: title), context: context)
    // The full command stays with the terminal so the person can copy and rerun it themselves.
    _ = try await store.dispatch(
      .setNodeSubtitle(id: nodeID, subtitle: command), context: context)
  }
  do {
    _ = try await supervisor.spawnTerminal(
      shell: executable,
      command: command,
      workingDirectory: workspacePath,
      id: nodeID,
      canvasID: canvasID
    )
  } catch {
    _ = try? await store.dispatch(.closeNode(nodeID), context: context)
    throw error
  }
  var output = try await terminalOutput(id: nodeID, supervisor: supervisor)
  output.title = title
  output.whereToFindIt =
    "In the work panel on the right of this chat, in the tab titled \"\(title)\". "
    + "Open the work panel to view it. The person can click into it to type or paste."
  return output
}

private func validatedShell(_ shell: String) throws -> String {
  guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else {
    throw ToolRegistryError.invalidInput("Shell must be an absolute executable path")
  }
  return shell
}

private func terminalControlDefinition(name: String, description: String) -> ToolDefinition {
  let inputSchema: JSONValue
  switch name {
  case "terminal.send_input":
    inputSchema = .objectSchema(
      properties: [
        "terminalID": .stringSchema(description: "Stable terminal node UUID"),
        "text": .stringSchema(description: "Text or command to type into the terminal"),
      ],
      required: ["terminalID", "text"]
    )
  case "terminal.send_bytes":
    inputSchema = .objectSchema(
      properties: [
        "terminalID": .stringSchema(description: "Stable terminal node UUID"),
        "data": .stringSchema(description: "Base64-encoded terminal input bytes"),
      ],
      required: ["terminalID", "data"]
    )
  case "terminal.resize":
    inputSchema = .objectSchema(
      properties: [
        "terminalID": .stringSchema(description: "Stable terminal node UUID"),
        "columns": .integerSchema(description: "Terminal columns from 20 through 500"),
        "rows": .integerSchema(description: "Terminal rows from 4 through 300"),
      ],
      required: ["terminalID", "columns", "rows"]
    )
  default:
    inputSchema = terminalIDSchema()
  }
  return ToolDefinition(
    name: name,
    description: description,
    inputSchema: inputSchema,
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.terminalControl],
    riskLevel: .consequential
  )
}

private func terminalIDSchema() -> JSONValue {
  .objectSchema(
    properties: ["terminalID": .stringSchema(description: "Stable terminal node UUID")],
    required: ["terminalID"]
  )
}

private func terminalOutput(id: UUID, supervisor: AgentSupervisor) async throws -> TerminalOutput {
  let snapshot = try await supervisor.snapshot(agentID: id)
  let waiting =
    snapshot.state == .waitingUser
    && TerminalInputWaitDetector.isTerminalAttentionToken(snapshot.attentionToken)
  return TerminalOutput(
    terminalID: id,
    state: snapshot.state,
    exitCode: snapshot.exitCode,
    boundedOutput: TerminalOutputSearch.sanitizedExcerpt(snapshot.output),
    waitingForUser: waiting ? true : nil,
    prompt: waiting ? snapshot.attentionReason : nil
  )
}

private func terminalHasFinished(_ output: TerminalOutput) -> Bool {
  output.exitCode != nil
    || [.done, .failed, .interrupted, .stopped].contains(output.state)
}
