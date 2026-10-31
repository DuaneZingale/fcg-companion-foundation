import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("One-shot permission approvals")
struct AgentPermissionTests {
  @Test("Browser approvals follow live bypass and revocation")
  func liveBrowserBypass() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let browser = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "browser.click")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.setProviderPermissionBypass(agentID: id, enabled: true)
    #expect(try await browser.value)
    #expect(await !supervisor.hasPendingPermission(agentID: id))
    let account = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "browser.account")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.setProviderPermissionBypass(agentID: id, enabled: true)
    #expect(try await supervisor.requestPermission(agentID: id, toolName: "browser.click"))
    #expect(await supervisor.hasPendingPermission(agentID: id))
    #expect(
      try await supervisor.snapshot(agentID: id).attentionReason?.contains("browser.account")
        == true)
    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await account.value == false)
    #expect(try await supervisor.requestPermission(agentID: id, toolName: "browser.click"))

    try await supervisor.setProviderPermissionBypass(agentID: id, enabled: false)
    let revoked = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "browser.click")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await revoked.value == false)
    try await supervisor.stop(agentID: id)
  }

  @Test(
    "Launch and resume inherit browser bypass only for unrestricted sessions",
    arguments: ["oneShot", "interactive", "resume"],
    [AgentPermissionMode.readOnly, .workspaceWrite, .unrestricted]
  )
  func browserBypassAtLaunch(launch: String, mode: AgentPermissionMode) async throws {
    let supervisor = AgentSupervisor()
    let request = AgentLaunchRequest(
      workspacePath: FileManager.default.temporaryDirectory.path,
      prompt: launch == "interactive" ? nil : "fixture", permissionMode: mode)
    let id: UUID
    switch launch {
    case "interactive":
      id = try await supervisor.spawnInteractive(
        adapter: PermissionFixtureAdapter(), request: request)
    case "resume":
      id = try await supervisor.resumeOneShot(
        adapter: PermissionFixtureAdapter(), request: request, sessionID: "fixture", id: UUID())
    default:
      id = try await supervisor.spawnOneShot(adapter: PermissionFixtureAdapter(), request: request)
    }
    if mode == .unrestricted {
      #expect(try await supervisor.requestPermission(agentID: id, toolName: "browser.click"))
      #expect(await !supervisor.hasPendingPermission(agentID: id))
    } else {
      let click = Task {
        try await supervisor.requestPermission(agentID: id, toolName: "browser.click")
      }
      try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
      try await supervisor.resolvePermission(agentID: id, approved: false)
      #expect(try await click.value == false)
    }
    try await supervisor.stop(agentID: id)
  }

  @Test(
    "Always allow applies to the current run and can be revoked without bypassing app confirmations"
  )
  func liveProviderBypass() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let first = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "Write", isProviderPermission: true)
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.setProviderPermissionBypass(agentID: id, enabled: true)
    #expect(try await first.value)
    #expect(
      try await supervisor.requestPermission(
        agentID: id, toolName: "Bash", isProviderPermission: true))
    #expect(await !supervisor.hasPendingPermission(agentID: id))

    let account = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "browser.account")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await account.value == false)

    try await supervisor.setProviderPermissionBypass(agentID: id, enabled: false)
    let revoked = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "Write", isProviderPermission: true)
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await revoked.value == false)
    try await supervisor.stop(agentID: id)
  }

  @Test("Expired browser approvals clear the card and cannot be approved later")
  func browserApprovalExpires() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let decision = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "browser.click", timeout: .milliseconds(100))
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))
    await #expect(throws: RuntimeError.permissionExpired) { try await decision.value }
    #expect(await !supervisor.hasPendingPermission(agentID: id))
    #expect(try await supervisor.snapshot(agentID: id).state == .working)
    #expect(
      try await supervisor.snapshot(agentID: id).transcript.last?.text.contains("expired") == true)
    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(
        agentID: id, requestID: pending.requestID, nonce: pending.nonce, approved: true)
    }
    try await supervisor.stop(agentID: id)
  }

  @Test("Expiry of a queued request leaves the first approval intact")
  func queuedExpiryPreservesFirst() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let first = Task { try await supervisor.requestPermission(agentID: id, toolName: "Write") }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))
    // Remote surfaces decide by the asking tool, not by its display text.
    #expect(pending.toolName == "Write")
    let second = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "browser.click", timeout: .milliseconds(50))
    }
    await #expect(throws: RuntimeError.permissionExpired) { try await second.value }
    #expect(await supervisor.pendingPermission(agentID: id)?.requestID == pending.requestID)
    try await supervisor.resolvePermission(
      agentID: id, requestID: pending.requestID, nonce: pending.nonce, approved: true)
    #expect(try await first.value)
    try await supervisor.stop(agentID: id)
  }

  @Test("An approved request's timer cannot expire the next approval")
  func approvedTimerCannotExpireNext() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let first = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "browser.click", timeout: .milliseconds(100))
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: id, approved: true)
    #expect(try await first.value)
    let second = Task { try await supervisor.requestPermission(agentID: id, toolName: "Write") }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))
    try await Task.sleep(for: .milliseconds(150))
    #expect(await supervisor.pendingPermission(agentID: id)?.requestID == pending.requestID)
    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await second.value == false)
    try await supervisor.stop(agentID: id)
  }

  @Test("Claude one-shot launches route approvals through the otto permission tool")
  func oneShotLaunchWiresPermissionPromptTool() async throws {
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "List the repository files.",
        permissionMode: .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp"
      ))
    let flagIndex = try #require(spec.arguments.firstIndex(of: "--permission-prompt-tool"))
    #expect(spec.arguments[flagIndex + 1] == AgentPermissionPrompt.mcpToolName)
    #expect(spec.arguments.contains("--mcp-config"))
    // The prompt stays the final positional argument, after every flag.
    #expect(spec.arguments.last == "List the repository files.")
  }

  @Test("Claude pre-approves only the Otto tools Otto confirms itself, never the whole server")
  func claudeAllowsOnlySelfConfirmingOttoTools() async throws {
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "Send the report.",
        permissionMode: .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp",
        ottoSelfConfirmingTools: ["smtp.send", "calendar.create_event"]
      ))
    let index = try #require(spec.arguments.firstIndex(of: "--allowedTools"))
    #expect(spec.arguments[index + 1] == "mcp__otto__smtp_send,mcp__otto__calendar_create_event")
    // A server-wide grant would let terminal.open, agent.spawn, ... skip every prompt.
    #expect(!spec.arguments.contains("mcp__otto"))
    #expect(!spec.arguments[index + 1].contains("terminal_run"))
    // The next argument is a flag, so the variadic list ends before the prompt.
    #expect(spec.arguments[index + 2].hasPrefix("--"))
    #expect(spec.arguments.last == "Send the report.")

    let readOnly = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .readOnly,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp",
        ottoSelfConfirmingTools: ["smtp.send"]
      ))
    #expect(!readOnly.arguments.contains("--allowedTools"))

    let noList = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "Run the tests.",
        permissionMode: .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp"
      ))
    #expect(!noList.arguments.contains("--allowedTools"))
  }

  @Test("Claude in a project folder can read chat images staged in Otto's workspace")
  func claudeAddsOttoAttachmentsDirectory() async throws {
    let otto = FileManager.default.temporaryDirectory.appending(path: "otto-\(UUID())")
    let attachments = otto.appending(path: ".otto/chat-attachments")
    try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: otto) }
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "Look at the screenshot.",
        ottoWorkspacePath: otto.path
      ))
    let index = try #require(spec.arguments.firstIndex(of: "--add-dir"))
    #expect(spec.arguments[index + 1] == attachments.path)
    #expect(spec.arguments[index + 2].hasPrefix("--"))
    #expect(spec.arguments.last == "Look at the screenshot.")

    let inWorkspace = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: otto.path, prompt: "Look at the screenshot.", ottoWorkspacePath: otto.path
      ))
    #expect(!inWorkspace.arguments.contains("--add-dir"))
  }

  @Test("Codex pre-approves only self-confirming Otto tools, and nothing when read-only")
  func codexApprovesOnlySelfConfirmingOttoTools() async throws {
    let adapter = CodexAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "Send the report.",
        permissionMode: .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp",
        ottoSelfConfirmingTools: ["smtp.send", "gmail.send"]
      ))
    #expect(
      spec.arguments.contains(
        "mcp_servers.otto.tools={\"smtp.send\"={approval_mode=\"approve\"},"
          + "\"gmail.send\"={approval_mode=\"approve\"}}"))
    #expect(!spec.arguments.contains { $0.contains("default_tools_approval_mode") })
    // Tools absent from the self-confirming list keep Codex's own approval policy.
    #expect(
      !spec.arguments.contains {
        $0.hasPrefix("mcp_servers.otto.tools") && $0.contains("terminal.run")
      })

    let readOnly = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "Look around.",
        permissionMode: .readOnly,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp",
        ottoSelfConfirmingTools: ["smtp.send"]
      ))
    #expect(!readOnly.arguments.contains { $0.contains("approval_mode") })
  }

  @Test("The permission prompt flag requires the otto MCP bridge")
  func noPermissionPromptToolWithoutBridge() async throws {
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "List the repository files.",
        permissionMode: .workspaceWrite
      ))
    #expect(!spec.arguments.contains("--permission-prompt-tool"))
  }

  @Test("Interactive launches keep the native TUI permission prompt")
  func noPermissionPromptToolForInteractiveLaunches() async throws {
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp"
      ))
    #expect(spec.arguments.contains("--mcp-config"))
    #expect(!spec.arguments.contains("--permission-prompt-tool"))
  }

  @Test("Approval surfaces WAITING_PERMISSION and resumes the parked request")
  func approvalRoundTrip() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)

    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "git push")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let waiting = try await supervisor.snapshot(agentID: id)
    #expect(waiting.attentionReason == "Bash: git push")
    #expect(await supervisor.hasPendingPermission(agentID: id))

    try await supervisor.resolvePermission(agentID: id, approved: true)
    #expect(try await decision.value == true)

    let resumed = try await supervisor.snapshot(agentID: id)
    #expect(resumed.state == .working)
    #expect(resumed.attentionReason == nil)
    #expect(resumed.transcript.last?.kind == .notice)
    #expect(resumed.transcript.last?.text == "Approved Bash: git push")
    #expect(await !supervisor.hasPendingPermission(agentID: id))
    try await supervisor.stop(agentID: id)
  }

  @Test("Denial resumes the parked request with a refusal")
  func denialRoundTrip() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)

    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Write")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: id).attentionReason == "Wants to use Write")

    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await decision.value == false)

    let resumed = try await supervisor.snapshot(agentID: id)
    #expect(resumed.state == .working)
    #expect(resumed.transcript.last?.text == "Denied Wants to use Write")
    try await supervisor.stop(agentID: id)
  }

  @Test("Remote approval validates the surfaced request ID and nonce exactly once")
  func nonceBoundApproval() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let decision = Task {
      try await supervisor.requestPermission(
        agentID: id,
        toolName: "Bash",
        detail: "publish the release tag"
      )
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))

    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(
        agentID: id,
        requestID: pending.requestID,
        nonce: "wrong-nonce",
        approved: true
      )
    }
    #expect(await supervisor.hasPendingPermission(agentID: id))

    try await supervisor.resolvePermission(
      agentID: id,
      requestID: pending.requestID,
      nonce: pending.nonce,
      approved: true
    )
    #expect(try await decision.value)
    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(
        agentID: id,
        requestID: pending.requestID,
        nonce: pending.nonce,
        approved: true
      )
    }
    try await supervisor.stop(agentID: id)
  }

  @Test("Queued requests resolve in arrival order and keep the surfaced reason current")
  func queuedRequestsResolveInOrder() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)

    let first = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "rm -rf tmp")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let second = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "WebFetch")
    }
    try await waitFor(supervisor: supervisor) {
      let hasPending = await supervisor.hasPendingPermission(agentID: id)
      let state = (try? await supervisor.snapshot(agentID: id))?.state
      return hasPending && state == .waitingPermission
    }
    // The card resolves in arrival order, so the first request owns the surfaced reason.
    #expect(try await supervisor.snapshot(agentID: id).attentionReason == "Bash: rm -rf tmp")

    try await supervisor.resolvePermission(agentID: id, approved: true)
    #expect(try await first.value == true)
    let betweenRequests = try await supervisor.snapshot(agentID: id)
    #expect(betweenRequests.state == .waitingPermission)
    #expect(betweenRequests.attentionReason == "Wants to use WebFetch")

    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await second.value == false)
    #expect(try await supervisor.snapshot(agentID: id).state == .working)
    try await supervisor.stop(agentID: id)
  }

  @Test("Process exit denies every parked permission request")
  func exitDeniesPendingRequests() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        // Wait for explicit test input instead of racing a wall-clock sleep against the full
        // suite's parallel load. Reading one line then exiting still exercises natural process
        // teardown rather than supervisor.stop().
        arguments: ["-c", "read line"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .claude(ClaudeOutputParser()),
      initialState: .working,
      executionMode: .oneShotProvider
    )
    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "ls")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.sendInput(agentID: id, text: "exit")
    #expect(try await decision.value == false)
    #expect(await !supervisor.hasPendingPermission(agentID: id))
  }

  @Test("Stopping an agent denies its parked permission request")
  func stopDeniesPendingRequests() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "ls")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.stop(agentID: id)
    #expect(try await decision.value == false)
  }

  @Test("Resolving without a parked request is an explicit error")
  func resolveWithoutPendingRequestThrows() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(agentID: id, approved: true)
    }
    try await supervisor.stop(agentID: id)
  }

  @Test("Requests for unknown or exited agents are rejected")
  func requestForUnknownAgentThrows() async throws {
    let supervisor = AgentSupervisor()
    await #expect(throws: RuntimeError.self) {
      _ = try await supervisor.requestPermission(agentID: UUID(), toolName: "Bash")
    }
  }

  @Test("Provider stream records while an approval is parked keep the card on screen")
  func claudeStreamKeepsParkedApproval() async throws {
    let supervisor = AgentSupervisor()
    // Claude Code keeps printing stream-json while it waits on the permission prompt tool: the
    // rest of the assistant message's content blocks and system records, each reporting WORKING.
    let id = try await spawnOneShotEmitting(
      [
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/notes.md"}}]}}"#,
        #"{"type":"system","subtype":"status","session_id":"claude-session"}"#,
      ],
      parser: .claude(ClaudeOutputParser()),
      supervisor: supervisor
    )
    let decision = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "Bash", detail: "swift build", isProviderPermission: true)
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.sendInput(agentID: id, text: "emit")
    try await waitFor(supervisor: supervisor) {
      (try? await supervisor.snapshot(agentID: id))?.providerSessionID == "claude-session"
    }

    let parked = try await supervisor.snapshot(agentID: id)
    #expect(parked.transcript.contains { $0.kind == .toolCall && $0.text == "/tmp/notes.md" })
    #expect(parked.state == .waitingPermission)
    #expect(parked.attentionReason == "Bash: swift build")
    #expect(await supervisor.hasPendingPermission(agentID: id))

    try await supervisor.resolvePermission(agentID: id, approved: true)
    #expect(try await decision.value)
    let resumed = try await supervisor.snapshot(agentID: id)
    #expect(resumed.state == .working)
    #expect(resumed.attentionReason == nil)
    try await supervisor.stop(agentID: id)
  }

  @Test("An idle record from the provider cannot hide a parked approval")
  func codexIdleKeepsParkedApproval() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnOneShotEmitting(
      [#"{"type":"thread.started","thread_id":"codex-thread"}"#],
      parser: .codex(CodexOutputParser()),
      supervisor: supervisor
    )
    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "browser.account")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.sendInput(agentID: id, text: "emit")
    try await waitFor(supervisor: supervisor) {
      (try? await supervisor.snapshot(agentID: id))?.providerSessionID == "codex-thread"
    }

    let parked = try await supervisor.snapshot(agentID: id)
    #expect(parked.state == .waitingPermission)
    #expect(parked.attentionReason == "Wants to use browser.account")
    // An idle run accepts a new prompt; a parked one must not, or the request is orphaned.
    await #expect(throws: RuntimeError.self) {
      try await supervisor.sendPrompt(agentID: id, prompt: "next")
    }

    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await decision.value == false)
    try await supervisor.stop(agentID: id)
  }

  @Test("Provider stream records while a question is parked keep its choices on screen")
  func claudeStreamKeepsParkedQuestion() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnOneShotEmitting(
      [#"{"type":"system","subtype":"status","session_id":"claude-question"}"#],
      parser: .claude(ClaudeOutputParser()),
      supervisor: supervisor
    )
    let answer = Task {
      try await supervisor.requestChoice(
        agentID: id, question: "Which branch?", choices: ["main", "release"])
    }
    try await waitForPermissionState(.waitingUser, id: id, supervisor: supervisor)
    try await supervisor.sendInput(agentID: id, text: "emit")
    try await waitFor(supervisor: supervisor) {
      (try? await supervisor.snapshot(agentID: id))?.providerSessionID == "claude-question"
    }

    let parked = try await supervisor.snapshot(agentID: id)
    #expect(parked.state == .waitingUser)
    #expect(parked.attentionToken == "agent-choice")
    #expect(parked.pendingChoice?.choices == ["main", "release"])

    try await supervisor.resolveChoice(agentID: id, answer: "release")
    #expect(try await answer.value == "release")
    #expect(try await supervisor.snapshot(agentID: id).state == .working)
    try await supervisor.stop(agentID: id)
  }

  /// A one-shot run that prints the given stream records once the test writes a line, so the
  /// records land strictly after a request has been parked.
  private func spawnOneShotEmitting(
    _ records: [String], parser: ProviderParser, supervisor: AgentSupervisor
  ) async throws -> UUID {
    let quoted = records.map { "'\($0)'" }.joined(separator: " ")
    return try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "read line; printf '%s\\n' \(quoted); sleep 20"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: parser,
      initialState: .working,
      executionMode: .oneShotProvider
    )
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

  private func waitForPermissionState(
    _ expected: AgentLifecycleState,
    id: UUID,
    supervisor: AgentSupervisor
  ) async throws {
    try await waitFor(supervisor: supervisor) {
      (try? await supervisor.snapshot(agentID: id))?.state == expected
    }
  }

  private func waitFor(
    supervisor: AgentSupervisor,
    timeout: Duration = .seconds(10),
    _ condition: () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for permission state condition")
  }
}

private struct PermissionFixtureAdapter: AgentAdapter {
  let provider = AgentProvider.claudeCode
  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }
  func availableModels() async -> [AgentModel] { [] }
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh", arguments: ["-c", "sleep 20"],
      workingDirectory: request.workspacePath)
  }
}
