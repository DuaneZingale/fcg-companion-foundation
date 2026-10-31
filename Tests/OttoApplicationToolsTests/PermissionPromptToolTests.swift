import Foundation
import OttoApplicationTools
import OttoControl
import OttoCore
import OttoMCP
import OttoModels
import OttoRuntime
import OttoTools
import Testing

private struct ConfirmedActionInput: Codable, Sendable { var value: String }

private struct ConfirmedActionTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.confirmed_action",
    description: "Runs a test action after confirmation.",
    inputSchema: .objectSchema(
      properties: ["value": .stringSchema()],
      required: ["value"]
    ),
    outputSchema: .object(["type": .string("string")]),
    requiredScopes: [.agentRead],
    riskLevel: .consequential,
    requiresConfirmation: true
  )

  func call(_ input: ConfirmedActionInput, context: ToolContext) async throws -> String {
    input.value
  }
}

/// The MCP bridge is synchronous and blocks until the control socket answers, exactly like
/// otto-mcp's stdio loop. Running it on a Swift concurrency thread can starve the small cooperative
/// pool of a CI runner, so the actor that must answer never runs. Park it on its own thread.
private func onDedicatedThread<T: Sendable>(
  _ body: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
  }
}

private actor BrowserActionCounter {
  private(set) var calls = 0
  func record() { calls += 1 }
}

private struct ExpiringBrowserActionTool: OttoTool {
  static let definition = ToolDefinition(
    name: "browser.click", description: "Test browser confirmation",
    inputSchema: .objectSchema(properties: [:], required: []),
    outputSchema: .object(["type": .string("string")]),
    requiredScopes: [.agentRead], riskLevel: .consequential, requiresConfirmation: true)
  let counter: BrowserActionCounter
  func call(_ input: EmptyInput, context: ToolContext) async throws -> String {
    await counter.record()
    return "clicked"
  }
  struct EmptyInput: Codable, Sendable {}
}

@Suite("In-chat permission prompt tool")
struct PermissionPromptToolTests {
  @Test("Terminal commands require a fresh decision; deny and cancellation never launch")
  func terminalCommandApprovalRoundTrip() async throws {
    let directory = URL(fileURLWithPath: "/tmp/otto-terminal-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let marker = directory.appending(path: "executions")
    let canvas = OttoCanvas(name: "Terminal approval")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    try await registry.register(
      TerminalRunTool(store: store, supervisor: supervisor, workspacePath: directory.path))
    try await registry.register(TerminalWaitTool(supervisor: supervisor))
    try await registry.register(TerminalReadOutputTool(supervisor: supervisor))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)
    // Even the provider-bypass preference must not bypass an explicit app command card.
    try await supervisor.setProviderPermissionBypass(agentID: agentID, enabled: true)
    let authenticator = ControlAuthenticator()
    let scopes: Set<ToolScope> = [.agentRead, .canvasRead, .canvasWrite, .terminalControl]
    let token = await authenticator.issue(
      actorID: "otto-agent-\(agentID)", scopes: scopes,
      source: .agent, sourceNodeID: agentID, sourceCanvasID: canvas.id)
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry, authenticator: authenticator)
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let command = "printf 'executed\\n' >> '\(marker.path)'; printf 'approved-output'"
    let arguments = try JSONValue.encode(
      TerminalRunInput(command: command, x: 0, y: 0, shell: "/bin/sh"))
    // Approval is not a substitute for the existing terminal scope.
    await #expect(throws: ToolRegistryError.self) {
      try await registry.call(
        name: "terminal.run", input: arguments,
        context: ToolContext(actorID: "read-only", scopes: [.agentRead], confirmed: true))
    }
    var approvedTerminalID: UUID?
    for step in 0..<4 {
      let cancellation = MCPRequestCancellation()
      let bridge = MCPBridge(
        client: ControlClient(socketPath: server.socketPath, token: token),
        isCancelled: { cancellation.isCancelled })
      let response = Task {
        try await onDedicatedThread {
          try bridge.handle(MCPRequest(
            id: .number(Double(step)), method: "tools/call",
            params: .object(["name": .string("terminal.run"), "arguments": arguments])))
        }
      }
      try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
      #expect(try await supervisor.snapshot(agentID: agentID).attentionReason ==
        "terminal.run: Shell: /bin/sh\nCommand:\n\(command)")
      let before = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
      #expect(before == (step < 2 ? "" : "executed\n"))
      if step == 3 { cancellation.cancel() }
      try await supervisor.resolvePermission(agentID: agentID, approved: step == 1 || step == 3)
      let result = try await response.value
      #expect(result.result?["isError"] == .bool(step != 1))
      if step == 1 {
        guard case .array(let content)? = result.result?["content"],
          let text = content.first?["text"]?.stringValue else {
          Issue.record("Missing terminal result")
          continue
        }
        let run = try JSONDecoder().decode(TerminalOutput.self, from: Data(text.utf8))
        approvedTerminalID = run.terminalID
        try await waitForState(.done, id: run.terminalID, supervisor: supervisor)
      }
      #expect(((try? String(contentsOf: marker, encoding: .utf8)) ?? "") ==
        (step == 0 ? "" : "executed\n"))
    }
    let terminalID = try #require(approvedTerminalID)
    // Reading the result of an approved command never asks again.
    for name in ["terminal.wait", "terminal.read_output"] {
      let bridge = MCPBridge(client: ControlClient(socketPath: server.socketPath, token: token))
      let result = try await onDedicatedThread {
        try bridge.handle(MCPRequest(
          id: .number(8), method: "tools/call",
          params: .object(["name": .string(name), "arguments": .object([
            "terminalID": .string(terminalID.uuidString)])])))
      }
      #expect(result.result?["isError"] == .bool(false))
      #expect(await !supervisor.hasPendingPermission(agentID: agentID))
      if case .array(let content)? = result.result?["content"] {
        #expect(content.first?["text"]?.stringValue?.contains("approved-output") == true)
      } else { Issue.record("Missing command output") }
    }
    await supervisor.stopAll()
  }

  @Test("Terminal approval shows the entire command and refuses hidden or oversized input")
  func terminalApprovalDoesNotTruncate() async throws {
    let supervisor = AgentSupervisor()
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)
    let tool = AgentRequestPermissionTool(supervisor: supervisor)
    let command = "printf '" + String(repeating: "a", count: 500) + "'; echo visible-suffix"
    let response = Task {
      try await tool.call(
        AgentPermissionPromptInput(toolName: "terminal.run", input: .object([
          "command": .string(command), "shell": .string("/bin/sh")])),
        context: agentContext(agentID: agentID))
    }
    try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: agentID).attentionReason?.hasSuffix(command) == true)
    try await supervisor.resolvePermission(agentID: agentID, approved: false)
    #expect(try await response.value.behavior == "deny")
    for bad in [String(repeating: "a", count: 8_001), "echo ok\u{1B}[8mhidden", "echo ok\u{202E}hidden"] {
      let result = try await tool.call(
        AgentPermissionPromptInput(toolName: "terminal.run", input: .object(["command": .string(bad)])),
        context: agentContext(agentID: agentID))
      #expect(result.behavior == "deny")
      #expect(await !supervisor.hasPendingPermission(agentID: agentID))
    }
    try await supervisor.stop(agentID: agentID)
  }

  @Test("Both provider adapters defer only the guarded terminal command to Otto")
  func terminalApprovalProviderHandoff() async throws {
    let guarded = [TerminalRunTool.definition, TerminalWaitTool.definition,
      TerminalReadOutputTool.definition, TerminalOpenTool.definition]
      .filter(\.requiresConfirmation).map(\.name)
    #expect(guarded == ["terminal.run"])
    let reads = [TerminalWaitTool.definition, TerminalReadOutputTool.definition, KnowledgeReadTool.definition]
      .filter(\.allowsUnpromptedRead).map(\.name)
    for readOnly in [false, true] {
      let request = AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath, prompt: "Read knowledge",
        permissionMode: readOnly ? .readOnly : .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp", ottoSelfConfirmingTools: guarded,
        ottoReadOnlyTools: reads)
      let codex = try await CodexAdapter(executablePath: "/bin/echo").buildLaunchSpec(request)
      let claude = try await ClaudeCodeAdapter(executablePath: "/bin/echo").buildLaunchSpec(request)
      for name in guarded {
        #expect(codex.arguments.contains { $0.contains("\"\(name)\"={approval_mode=\"approve\"}") } == !readOnly)
        #expect(claude.arguments.contains { $0.contains("mcp__otto__" + name.replacingOccurrences(of: ".", with: "_")) } == !readOnly)
      }
      for name in reads {
        #expect(codex.arguments.contains { $0.contains("\"\(name)\"={approval_mode=\"approve\"}") })
        #expect(claude.arguments.contains { $0.contains("mcp__otto__" + name.replacingOccurrences(of: ".", with: "_")) })
      }
      #expect(!codex.arguments.contains { $0.contains("default_tools_approval_mode") })
      #expect(!claude.arguments.contains("mcp__otto"))
    }
  }

  @Test("Browser clicks replay once without an approval card in bypass mode")
  func bridgeBypassClicksOnce() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    let counter = BrowserActionCounter()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    try await registry.register(ExpiringBrowserActionTool(counter: counter))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)
    try await supervisor.setProviderPermissionBypass(agentID: agentID, enabled: true)
    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(
      actorID: "otto-agent-\(agentID.uuidString)", scopes: [.agentRead],
      source: .agent, sourceNodeID: agentID)
    let directory = URL(fileURLWithPath: "/tmp/otto-bypass-\(UUID().uuidString.prefix(10))")
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry, authenticator: authenticator)
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let bridge = MCPBridge(client: ControlClient(socketPath: server.socketPath, token: token))
    let response = try await onDedicatedThread {
      try bridge.handle(
        MCPRequest(
          id: .number(1), method: "tools/call",
          params: .object(["name": .string("browser.click"), "arguments": .object([:])])))
    }
    #expect(response.result?["isError"] != .bool(true))
    #expect(await counter.calls == 1)
    #expect(await !supervisor.hasPendingPermission(agentID: agentID))
    try await supervisor.stop(agentID: agentID)
  }

  @Test(
    "The MCP bridge never replays an expired or cancelled browser click", arguments: [false, true])
  func bridgeExpiryDoesNotClick(cancel: Bool) async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    let counter = BrowserActionCounter()
    try await registry.register(
      AgentRequestPermissionTool(
        supervisor: supervisor,
        browserConfirmationTimeout: cancel ? .seconds(2) : .milliseconds(100)))
    try await registry.register(ExpiringBrowserActionTool(counter: counter))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)
    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(
      actorID: "otto-agent-\(agentID.uuidString)", scopes: [.agentRead],
      source: .agent, sourceNodeID: agentID)
    let directory = URL(fileURLWithPath: "/tmp/otto-expiry-\(UUID().uuidString.prefix(10))")
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry, authenticator: authenticator)
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let cancellation = MCPRequestCancellation()
    let bridge = MCPBridge(
      client: ControlClient(socketPath: server.socketPath, token: token),
      isCancelled: { cancellation.isCancelled })
    let pendingResponse = Task {
      try await onDedicatedThread {
        try bridge.handle(
          MCPRequest(
            id: .number(1), method: "tools/call",
            params: .object(["name": .string("browser.click"), "arguments": .object([:])])))
      }
    }
    if cancel {
      try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
      cancellation.cancel()
      try await supervisor.resolvePermission(agentID: agentID, approved: true)
    }
    let response = try await pendingResponse.value
    #expect(response.result?["isError"] == .bool(true))
    guard case .array(let content)? = response.result?["content"] else {
      Issue.record("Missing MCP error content")
      try await supervisor.stop(agentID: agentID)
      return
    }
    #expect(content.first?["text"]?.stringValue?.contains(cancel ? "cancelled" : "expired") == true)
    #expect(await counter.calls == 0)
    #expect(await !supervisor.hasPendingPermission(agentID: agentID))
    try await supervisor.stop(agentID: agentID)
  }

  @Test("A browser confirmation expires with a structured denial")
  func browserConfirmationExpires() async throws {
    let supervisor = AgentSupervisor()
    let tool = AgentRequestPermissionTool(
      supervisor: supervisor, browserConfirmationTimeout: .milliseconds(50))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)
    let result = try await tool.call(
      AgentPermissionPromptInput(toolName: "browser.click"),
      context: agentContext(agentID: agentID))
    #expect(result.behavior == "deny")
    #expect(result.message?.contains("expired") == true)
    #expect(await !supervisor.hasPendingPermission(agentID: agentID))
    try await supervisor.stop(agentID: agentID)
  }

  @Test("An approved request echoes the tool input back as an allow response")
  func approvedRequestAllows() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)

    let call = Task {
      try await registry.call(
        name: AgentPermissionPrompt.toolName,
        input: .object([
          "tool_name": .string("Bash"),
          "input": .object(["command": .string("git status")]),
          "tool_use_id": .string("toolu_01"),
          "permission_suggestions": .array([]),
        ]),
        context: agentContext(agentID: agentID)
      )
    }
    try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: agentID).attentionReason == "Bash: git status")
    try await supervisor.resolvePermission(agentID: agentID, approved: true)

    let output = try await call.value.decode(AgentPermissionPromptOutput.self)
    #expect(output.behavior == "allow")
    #expect(output.updatedInput == .object(["command": .string("git status")]))
    #expect(output.message == nil)
    try await supervisor.stop(agentID: agentID)
  }

  @Test("An email approval shows the recipient, subject and the whole body")
  func emailApprovalShowsMessage() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)
    let body = "Hi Amy,\n\n" + String(repeating: "The invoice is approved. ", count: 30) + "\nSam"

    let call = Task {
      try await registry.call(
        name: AgentPermissionPrompt.toolName,
        input: .object([
          "tool_name": .string("smtp.send"),
          "input": .object([
            "to": .string("amy@example.com"), "subject": .string("Re: Invoice"),
            "body": .string(body), "inReplyTo": .string("<m1@example.com>"),
          ]),
        ]),
        context: agentContext(agentID: agentID)
      )
    }
    try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
    let reason = try #require(try await supervisor.snapshot(agentID: agentID).attentionReason)
    #expect(reason.hasPrefix("smtp.send: Send email to amy@example.com\nSubject: Re: Invoice\n"))
    #expect(reason.contains("Reply in the original thread"))
    #expect(reason.hasSuffix(body))
    try await supervisor.resolvePermission(agentID: agentID, approved: false)
    _ = try await call.value
    try await supervisor.stop(agentID: agentID)
  }

  @Test("The approval card shows a long email in full, and one too long to show is refused")
  func longEmailBody() async throws {
    let body = String(repeating: "a", count: EmailApprovalSummary.bodyLimit)
    let input: [String: JSONValue] = [
      "to": .string("amy@example.com"), "subject": .string("Hi"), "body": .string(body),
    ]
    let text = try #require(EmailApprovalSummary.text(toolName: "gmail.send", input: input))
    #expect(text.hasSuffix(body))
    #expect(text.count + "gmail.send: ".count <= EmailApprovalSummary.limit)
    #expect(!text.contains("Reply in the original thread"))
    #expect(EmailApprovalSummary.text(toolName: "Bash", input: [:]) == nil)
    #expect(EmailApprovalSummary.refusal(input: input) == nil)

    var tooLong = input
    tooLong["body"] = .string(body + "hidden")
    #expect(EmailApprovalSummary.refusal(input: tooLong)?.contains("allows up to") == true)
    var escaped = input
    escaped["body"] = .string("Hi\u{1B}[8mhidden")
    #expect(EmailApprovalSummary.refusal(input: escaped) != nil)

    // The tool refuses before any card is shown.
    let supervisor = AgentSupervisor()
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)
    let output = try await AgentRequestPermissionTool(supervisor: supervisor).call(
      AgentPermissionPromptInput(toolName: "smtp.send", input: .object(tooLong)),
      context: agentContext(agentID: agentID))
    #expect(output.behavior == "deny")
    #expect(await !supervisor.hasPendingPermission(agentID: agentID))
    try await supervisor.stop(agentID: agentID)
  }

  @Test("The approval card says when a reply goes somewhere other than the original sender")
  func replyRecipientDiffersFromSender() {
    let input: [String: JSONValue] = [
      "to": .string("billing@evil.example"), "subject": .string("Re: Invoice"),
      "body": .string("Paid"), "messageID": .string("abc"),
    ]
    let redirected = EmailApprovalSummary.text(
      toolName: "gmail.reply", input: input,
      original: .init(from: "Amy <amy@example.com>", replyTo: "Billing <Billing@evil.example>"))
    #expect(
      redirected?.contains(
        "Not the original sender: amy@example.com asked for replies to go to billing@evil.example")
        == true)
    let other = EmailApprovalSummary.text(
      toolName: "gmail.reply", input: input, original: .init(from: "amy@example.com"))
    #expect(
      other?.contains("Not the original sender: the message came from amy@example.com") == true)
    let same = EmailApprovalSummary.text(
      toolName: "gmail.reply", input: input, original: .init(from: "<BILLING@evil.example>"))
    #expect(same?.contains("Not the original sender") == false)
  }

  @Test("A denied request returns the deny contract with a user-facing message")
  func deniedRequestExplains() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)

    let call = Task {
      try await registry.call(
        name: AgentPermissionPrompt.toolName,
        input: .object(["tool_name": .string("Write")]),
        context: agentContext(agentID: agentID)
      )
    }
    try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: agentID, approved: false)

    let output = try await call.value.decode(AgentPermissionPromptOutput.self)
    #expect(output.behavior == "deny")
    #expect(output.updatedInput == nil)
    #expect(output.message == "The user denied Write in Otto")
    try await supervisor.stop(agentID: agentID)
  }

  @Test("The agent node is recovered from the actor identity when the grant omits it")
  func recoversAgentFromActorID() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)

    let call = Task {
      try await registry.call(
        name: AgentPermissionPrompt.toolName,
        input: .object(["tool_name": .string("Bash"), "input": .object([:])]),
        context: ToolContext(
          actorID: "otto-agent-\(agentID.uuidString)",
          scopes: [.agentRead],
          source: .agent
        )
      )
    }
    try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: agentID, approved: true)
    let output = try await call.value.decode(AgentPermissionPromptOutput.self)
    #expect(output.behavior == "allow")
    try await supervisor.stop(agentID: agentID)
  }

  @Test("Unidentifiable or unknown agents receive a structured deny, never an error")
  func unknownAgentsDeny() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))

    let unidentified = try await registry.call(
      name: AgentPermissionPrompt.toolName,
      input: .object(["tool_name": .string("Bash")]),
      context: ToolContext(actorID: "otto-app", scopes: [.agentRead], source: .agent)
    ).decode(AgentPermissionPromptOutput.self)
    #expect(unidentified.behavior == "deny")
    #expect(unidentified.message?.contains("could not identify") == true)

    let unknown = try await registry.call(
      name: AgentPermissionPrompt.toolName,
      input: .object(["tool_name": .string("Bash")]),
      context: ToolContext(
        actorID: "otto-agent-\(UUID().uuidString)",
        scopes: [.agentRead],
        source: .agent
      )
    ).decode(AgentPermissionPromptOutput.self)
    #expect(unknown.behavior == "deny")
    #expect(unknown.message?.contains("could not route") == true)
  }

  @Test("A bridge tools/call blocks on the socket until the user approves in the app")
  func bridgeRoundTripApproves() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)

    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(
      actorID: "otto-agent-\(agentID.uuidString)",
      scopes: [.agentRead],
      source: .agent,
      sourceNodeID: agentID
    )
    let directory = URL(fileURLWithPath: "/tmp/otto-perm-\(UUID().uuidString.prefix(10))")
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry,
      authenticator: authenticator
    )
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let bridge = MCPBridge(client: ControlClient(socketPath: server.socketPath, token: token))

    let request = MCPRequest(
      id: .number(7),
      method: "tools/call",
      params: .object([
        "name": .string(AgentPermissionPrompt.toolName),
        "arguments": .object([
          "tool_name": .string("Bash"),
          "input": .object(["command": .string("swift test")]),
          "tool_use_id": .string("toolu_02"),
        ]),
      ])
    )
    // The bridge call is intentionally synchronous and blocking, exactly like otto-mcp's stdio
    // loop; it must stay parked well past the default ten-second socket timeout window's
    // semantics and only return once the approval lands.
    let response = Task { try await onDedicatedThread { try bridge.handle(request) } }
    try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: agentID, approved: true)

    let value = try await response.value
    #expect(value.error == nil)
    #expect(value.result?["isError"] == .bool(false))
    guard case .array(let content)? = value.result?["content"],
      let text = content.first?["text"]?.stringValue
    else {
      Issue.record("Bridge response carried no text content")
      return
    }
    let payload = try JSONDecoder().decode(
      AgentPermissionPromptOutput.self, from: Data(text.utf8))
    #expect(payload.behavior == "allow")
    #expect(payload.updatedInput == .object(["command": .string("swift test")]))
    try await supervisor.stop(agentID: agentID)
  }

  @Test("A bridge turns late-bound tool confirmation into an in-chat approval and retry")
  func bridgeRetriesConfirmedToolAfterApproval() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await registry.register(AgentRequestPermissionTool(supervisor: supervisor))
    try await registry.register(ConfirmedActionTool())
    let agentID = try await spawnLongRunningOneShot(supervisor: supervisor)

    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(
      actorID: "otto-agent-\(agentID.uuidString)",
      scopes: [.agentRead],
      source: .agent,
      sourceNodeID: agentID
    )
    let directory = URL(fileURLWithPath: "/tmp/otto-confirm-\(UUID().uuidString.prefix(10))")
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry,
      authenticator: authenticator
    )
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let bridge = MCPBridge(client: ControlClient(socketPath: server.socketPath, token: token))
    let request = MCPRequest(
      id: .number(8),
      method: "tools/call",
      params: .object([
        "name": .string(ConfirmedActionTool.definition.name),
        "arguments": .object(["value": .string("approved")]),
      ])
    )

    let response = Task { try await onDedicatedThread { try bridge.handle(request) } }
    try await waitForState(.waitingPermission, id: agentID, supervisor: supervisor)
    #expect(
      try await supervisor.snapshot(agentID: agentID).attentionReason?
        .contains("test.confirmed_action") == true)
    try await supervisor.resolvePermission(agentID: agentID, approved: true)

    let value = try await response.value
    #expect(value.result?["isError"] == .bool(false))
    guard case .array(let content)? = value.result?["content"] else {
      Issue.record("Bridge response carried no content")
      return
    }
    #expect(content.first?["text"] == .string(#""approved""#))
    try await supervisor.stop(agentID: agentID)
  }

  private func spawnLongRunningOneShot(supervisor: AgentSupervisor) async throws -> UUID {
    try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 20"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .claude(ClaudeOutputParser()),
      initialState: .working,
      executionMode: .oneShotProvider
    )
  }

  private func agentContext(agentID: UUID) -> ToolContext {
    ToolContext(
      actorID: "otto-agent-\(agentID.uuidString)",
      scopes: [.agentRead],
      source: .agent,
      sourceNodeID: agentID
    )
  }

  private func waitForState(
    _ expected: AgentLifecycleState,
    id: UUID,
    supervisor: AgentSupervisor,
    timeout: Duration = .seconds(10)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if try await supervisor.snapshot(agentID: id).state == expected { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(expected.rawValue)")
  }
}
