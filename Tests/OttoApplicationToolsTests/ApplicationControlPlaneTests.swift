import Darwin
import Foundation
import OttoApplicationTools
import OttoControl
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import OttoWorktrees
import Testing

@Suite("Otto application control plane")
struct ApplicationControlPlaneTests {
  @Test("New agents seed their expanded presentation from the default view")
  func newAgentUsesDefaultView() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-default-agent-view-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let suite = "otto.tests.agent-view.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    AgentDefaultView.terminal.save(to: defaults)

    let canvas = OttoCanvas(name: "Default agent view")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let spawn = AgentSpawnTool(
      store: store,
      supervisor: supervisor,
      workspacePath: directory.path,
      defaultsSuiteName: suite
    )
    let context = ToolContext(actorID: "default-view", scopes: [.canvasWrite, .agentControl])

    let created = try await spawn.call(
      AgentSpawnProviderInput(
        provider: .shell,
        x: 10,
        y: 20,
        permissionMode: .workspaceWrite
      ),
      context: context
    )
    let node = try #require(await store.activeCanvas.nodes.first)
    #expect(node.presentationMode == .terminal)
    #expect(node.lastExpandedPresentation == .terminal)
    #expect(node.effectiveExpandedPresentation == .terminal)
    try await supervisor.stop(agentID: created.agentID)
  }

  @Test("Background agents mutate their owning canvas without stealing user focus")
  func backgroundAgentCanvasIsolation() async throws {
    let foreground = OttoCanvas(name: "Foreground")
    let background = OttoCanvas(name: "Background")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [foreground, background],
        activeCanvasID: foreground.id
      ))
    let sourceReceipt = await store.dispatch(
      .createNode(kind: .agent, at: WorldPoint(x: 20, y: 30)),
      targetCanvasID: background.id
    )
    let sourceNodeID = try #require(sourceReceipt.affectedNodeIDs.first)
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor()
    )
    let context = ToolContext(
      actorID: "background-agent",
      scopes: [.canvasRead, .canvasWrite],
      source: .agent,
      sourceNodeID: sourceNodeID
    )

    let created = try await registry.call(
      name: "node.create",
      input: try JSONValue.encode(NodeCreateInput(kind: .markdown, x: 100, y: 200)),
      context: context
    ).decode(NodeCreateOutput.self)

    let snapshot = await store.snapshot
    #expect(snapshot.activeCanvasID == foreground.id)
    #expect(snapshot.canvases.first(where: { $0.id == foreground.id })?.nodes.isEmpty == true)
    #expect(
      snapshot.canvases.first(where: { $0.id == background.id })?.nodes.map(\.id)
        == [sourceNodeID, created.node.id]
    )

    await #expect(throws: ToolRegistryError.interactionDenied(.focusUserInterface)) {
      try await registry.call(
        name: "node.focus",
        input: try JSONValue.encode(NodeIDInput(nodeID: created.node.id)),
        context: context
      )
    }
    await #expect(throws: ToolRegistryError.unknownTool("canvas.switch")) {
      try await registry.call(
        name: "canvas.switch", input: .object([:]), context: context)
    }
    #expect(await store.snapshot.activeCanvasID == foreground.id)
  }

  @Test("Named agents persist their launch definition and can restart in the same node")
  func namedAgentDefinitionAndRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-named-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let canvas = OttoCanvas(name: "Named agents")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let sessions = WorktreeSessionStore()
    let spawn = AgentSpawnTool(
      store: store,
      supervisor: supervisor,
      workspacePath: directory.path,
      worktreeSessions: sessions
    )
    let context = ToolContext(actorID: "named-agent", scopes: [.canvasWrite, .agentControl])

    let created = try await spawn.call(
      AgentSpawnProviderInput(
        provider: .shell,
        displayName: "Maya",
        workingDirectory: directory.path,
        x: 10,
        y: 20,
        permissionMode: .readOnly,
        isolatedWorktree: false
      ),
      context: context
    )
    let node = try #require(await store.activeCanvas.nodes.first)
    #expect(node.id == created.agentID)
    #expect(node.displayName == "Maya")
    #expect(node.agentDefinition?.workingDirectory == directory.path)
    #expect(node.agentDefinition?.permissionMode == AgentPermissionMode.readOnly.rawValue)

    let restart = AgentRestartTool(
      store: store,
      supervisor: supervisor,
      worktreeSessions: sessions,
      adapters: [RestartFixtureAdapter()]
    )
    _ = try await restart.call(AgentStatusInput(agentID: created.agentID), context: context)
    #expect(
      try await supervisor.snapshot(agentID: created.agentID).executionMode == .interactiveProvider)
    #expect(await store.activeCanvas.nodes.first?.id == created.agentID)
    _ = try await supervisor.stopIfPresent(agentID: created.agentID)
  }

  @Test("Restart forwards a persisted provider session into the reopened harness")
  func restartUsesPersistedSession() async throws {
    let canvas = OttoCanvas(name: "Resume on reopen")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = await store.dispatch(
      .createNode(kind: .agent, at: WorldPoint(x: 10, y: 20)))
    let agentID = try #require(receipt.affectedNodeIDs.first)
    _ = await store.dispatch(.setNodeContent(id: agentID, content: .agent(provider: .codex)))
    _ = await store.dispatch(
      .setAgentDefinition(
        id: agentID,
        definition: AgentDefinition(
          provider: .codex,
          workingDirectory: "/tmp",
          launchCommand: "codex",
          permissionMode: AgentPermissionMode.readOnly.rawValue,
          resumeSessionID: "persisted-session"
        )
      ))
    let supervisor = AgentSupervisor()
    let restart = AgentRestartTool(
      store: store,
      supervisor: supervisor,
      worktreeSessions: WorktreeSessionStore(),
      adapters: [PersistedSessionRestartAdapter()]
    )
    let context = ToolContext(actorID: "restore-test", scopes: [.canvasWrite, .agentControl])

    _ = try await restart.call(AgentStatusInput(agentID: agentID), context: context)
    #expect(try await supervisor.snapshot(agentID: agentID).state == .idle)
    #expect(
      try await supervisor.snapshot(agentID: agentID).providerSessionID == "persisted-session")
    _ = try await supervisor.stopIfPresent(agentID: agentID)
    #expect(
      try await supervisor.snapshot(agentID: agentID).providerSessionID == "persisted-session")
  }

  @Test("A prompt revives a restored agent node the supervisor has never seen")
  func promptRevivesRestoredNode() async throws {
    // After an app relaunch, restored agent nodes exist on the canvas but the runtime has no
    // snapshot for them. Typing into one must relaunch it from the persisted definition and
    // resume the recorded provider session — the alternative is a bricked node whose only
    // recovery is closing it and starting over.
    let canvas = OttoCanvas(name: "Restored session")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = await store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
    let agentID = try #require(receipt.affectedNodeIDs.first)
    _ = await store.dispatch(.setNodeContent(id: agentID, content: .agent(provider: .codex)))
    _ = await store.dispatch(
      .setAgentDefinition(
        id: agentID,
        definition: AgentDefinition(
          provider: .codex,
          workingDirectory: FileManager.default.currentDirectoryPath,
          launchCommand: "codex",
          permissionMode: AgentPermissionMode.workspaceWrite.rawValue,
          resumeSessionID: "session-fixture"
        )
      ))

    let supervisor = AgentSupervisor()
    let tool = AgentSendPromptTool(
      supervisor: supervisor,
      store: store,
      workspacePath: FileManager.default.currentDirectoryPath,
      worktreeSessions: WorktreeSessionStore(),
      adapters: [ScriptedResumeAdapter()]
    )
    let revived = try await tool.call(
      AgentPromptInput(agentID: agentID, prompt: "pick up where we left off"),
      context: ToolContext(actorID: "restored-node-test", scopes: [.canvasWrite, .agentControl])
    )
    #expect(revived.agentID == agentID)

    try await waitForState(.done, agentID: agentID, supervisor: supervisor)
    let final = try await supervisor.snapshot(agentID: agentID)
    #expect(final.providerSessionID == "session-fixture")
    #expect(final.result == "Resumed pick up where we left off")
  }

  @Test("A chat prompt after harness restart preserves the saved session")
  func promptAfterHarnessRestartPreservesSession() async throws {
    // Relaunch first opens a native harness. Switching that harness to chat must carry the
    // persisted session through to the structured provider run.
    let canvas = OttoCanvas(name: "Restored session")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = await store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
    let agentID = try #require(receipt.affectedNodeIDs.first)
    _ = await store.dispatch(.setNodeContent(id: agentID, content: .agent(provider: .codex)))
    _ = await store.dispatch(
      .setAgentDefinition(
        id: agentID,
        definition: AgentDefinition(
          provider: .codex,
          workingDirectory: FileManager.default.currentDirectoryPath,
          launchCommand: "codex",
          permissionMode: AgentPermissionMode.workspaceWrite.rawValue,
          resumeSessionID: "session-fixture"
        )
      ))

    let supervisor = AgentSupervisor()
    _ = try await supervisor.spawnInteractive(
      adapter: ChatSwapAdapter(),
      request: AgentLaunchRequest(workspacePath: FileManager.default.currentDirectoryPath),
      id: agentID
    )
    let tool = AgentSendPromptTool(
      supervisor: supervisor,
      store: store,
      workspacePath: FileManager.default.currentDirectoryPath,
      worktreeSessions: WorktreeSessionStore(),
      adapters: [ScriptedResumeAdapter()]
    )
    let revived = try await tool.call(
      AgentPromptInput(agentID: agentID, prompt: "pick up where we left off"),
      context: ToolContext(actorID: "restored-node-test", scopes: [.canvasWrite, .agentControl])
    )
    #expect(revived.agentID == agentID)

    try await waitForState(.done, agentID: agentID, supervisor: supervisor)
    let final = try await supervisor.snapshot(agentID: agentID)
    #expect(final.providerSessionID == "session-fixture")
    #expect(final.result == "Resumed pick up where we left off")
  }

  @Test("Provider prompts reject NUL bytes and excessive payloads before node creation")
  func promptBoundaryValidation() async throws {
    let canvas = OttoCanvas(name: "Prompt security")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let context = ToolContext(
      actorID: "prompt-security", scopes: [.canvasWrite, .agentControl])

    for prompt in ["ignore\u{0}boundary", String(repeating: "a", count: 262_145)] {
      await #expect(throws: ToolRegistryError.self) {
        try await registry.call(
          name: "agent.spawn",
          input: try JSONValue.encode(
            AgentSpawnProviderInput(
              provider: .shell, prompt: prompt, x: 0, y: 0, isolatedWorktree: false)),
          context: context
        )
      }
    }
    #expect(await store.activeCanvas.nodes.isEmpty)
  }

  @Test("Diagnostics report readiness without exposing workspace paths")
  func privacySafeDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-private-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: ".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = ToolRegistry()
    try await registry.register(
      DiagnosticsRunTool(
        workspacePath: root.path,
        adapters: [ScriptedResumeAdapter(), MissingProviderAdapter()],
        mcpExecutablePath: "/bin/sh"
      ))

    let value = try await registry.call(
      name: "diagnostics.run",
      input: .object([:]),
      context: ToolContext(actorID: "diagnostics", scopes: [.canvasRead])
    )
    let report = try value.decode(DiagnosticReport.self)
    #expect(report.readyForLocalUse)
    #expect(report.checks.first(where: { $0.id == "workspace" })?.status == .pass)
    #expect(report.checks.first(where: { $0.id == "git" })?.status == .pass)
    #expect(report.checks.first(where: { $0.id == "mcp" })?.status == .pass)
    #expect(report.checks.first(where: { $0.id == "provider.claude-code" })?.status == .warning)
    #expect(!String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains(root.path))
  }

  @Test("Socket creates, prompts, completes, and retrieves a canvas agent")
  func agentLifecycleOverSocket() async throws {
    let emptyCanvas = OttoCanvas(name: "Control plane")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [emptyCanvas], activeCanvasID: emptyCanvas.id))
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: supervisor
    )
    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(
      actorID: "e2e",
      scopes: [.canvasRead, .canvasWrite, .agentRead, .agentControl]
    )
    let directory = URL(fileURLWithPath: "/tmp/otto-app-\(UUID().uuidString.prefix(10))")
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path,
      registry: registry,
      authenticator: authenticator
    )
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let client = ControlClient(socketPath: server.socketPath, token: token)

    let spawnedValue = try await client.callAsync(
      "agent.spawn_mock",
      arguments: .object(["x": .number(80), "y": .number(-40)])
    )
    let spawned = try spawnedValue.decode(AgentSpawnOutput.self)
    _ = try await waitForState(.idle, agentID: spawned.agentID, client: client)

    _ = try await client.callAsync(
      "agent.send_prompt",
      arguments: try JSONValue.encode(
        AgentPromptInput(agentID: spawned.agentID, prompt: "review authentication"))
    )
    let final = try await waitForState(.done, agentID: spawned.agentID, client: client)

    #expect(final.result == "Completed review authentication")
    #expect(final.boundedOutput.contains("Working on: review authentication"))
    #expect(await store.activeCanvas.nodes.map(\.id) == [spawned.agentID])
    #expect(await registry.auditLog().allSatisfy(\.succeeded))
  }

  @Test("Destructive close-all requires explicit confirmation and reports exact count")
  func closeAllConfirmation() async throws {
    let store = await CanvasStore()
    // Fresh workspaces no longer contain demo nodes. Seed the exact deletion fixture.
    for _ in 0..<3 {
      _ = await store.dispatch(.createNode(kind: .markdown, at: WorldPoint(x: 0, y: 0)))
    }
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: supervisor)
    let context = ToolContext(
      actorID: "voice",
      scopes: [.globalDestructive]
    )

    await #expect(throws: ToolRegistryError.confirmationRequired("node.close_all")) {
      try await registry.call(
        name: "node.close_all",
        input: .object([:]),
        context: context
      )
    }

    let output = try await registry.call(
      name: "node.close_all",
      input: .object([:]),
      context: ToolContext(
        actorID: "voice",
        scopes: [.globalDestructive],
        confirmed: true
      )
    )
    #expect(try output.decode(MutationOutput.self).message == "Closed 3 nodes")
  }

  @Test("Closing a process-backed node terminates its child process")
  func closingNodeStopsProcess() async throws {
    let canvas = OttoCanvas(name: "Process cleanup")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: supervisor
    )
    let context = ToolContext(
      actorID: "process-cleanup",
      scopes: [.canvasRead, .canvasWrite, .terminalControl], confirmed: true
    )
    let terminal = try await registry.call(
      name: "terminal.run",
      input: try JSONValue.encode(
        TerminalRunInput(command: "printf 'child=%s\\n' \"$$\"; sleep 30", x: 0, y: 0)),
      context: context
    ).decode(TerminalOutput.self)
    let childPID = try await waitForChildPID(
      terminalID: terminal.terminalID,
      supervisor: supervisor
    )
    #expect(kill(childPID, 0) == 0)

    let closed = try await registry.call(
      name: "node.close",
      input: try JSONValue.encode(NodeCloseInput(nodeID: terminal.terminalID)),
      context: context
    ).decode(MutationOutput.self)

    #expect(closed.affectedNodeIDs == [terminal.terminalID])
    #expect(await store.activeCanvas.nodes.isEmpty)
    #expect(try await supervisor.snapshot(agentID: terminal.terminalID).state == .stopped)
    try await waitForProcessToExit(childPID)
  }

  @Test("Agent output pages retain bounded absolute offsets")
  func agentOutputPaging() async throws {
    let supervisor = AgentSupervisor(scrollbackCapacity: 8)
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: CanvasStore(),
      supervisor: supervisor
    )
    let agentID = try await supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/usr/bin/printf",
        arguments: ["1234567890"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      successfulExitState: .done
    )
    try await waitForState(.done, agentID: agentID, supervisor: supervisor)
    let context = ToolContext(actorID: "output-reader", scopes: [.agentRead])

    let first = try await registry.call(
      name: "agent.get_output",
      input: try JSONValue.encode(
        AgentGetOutputInput(agentID: agentID, sinceOffset: 0, limit: 5)),
      context: context
    ).decode(AgentOutputPage.self)
    #expect(first.text == "34567")
    #expect(first.startOffset == 2)
    #expect(first.endOffset == 7)
    #expect(first.streamEndOffset == 10)
    #expect(first.truncated)

    let second = try await registry.call(
      name: "agent.get_output",
      input: try JSONValue.encode(
        AgentGetOutputInput(agentID: agentID, sinceOffset: first.endOffset)),
      context: context
    ).decode(AgentOutputPage.self)
    #expect(second.text == "890")
    #expect(second.startOffset == 7)
    #expect(second.endOffset == 10)
    #expect(!second.truncated)
  }

  @Test("Event wait broadcasts one typed completion to concurrent observers")
  func eventWaitBroadcasts() async throws {
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: CanvasStore(),
      supervisor: supervisor
    )
    let agentID = UUID()
    let input = try JSONValue.encode(
      EventWaitInput(
        types: [.agentRunCompleted],
        nodeID: agentID,
        afterSequence: supervisor.eventBus.latestSequence,
        timeoutMilliseconds: 2_000
      ))
    let context = ToolContext(actorID: "event-reader", scopes: [.agentRead])
    async let firstValue = registry.call(name: "event.wait", input: input, context: context)
    async let secondValue = registry.call(name: "event.wait", input: input, context: context)

    _ = try await supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c", "printf 'OTTO_RESULT:Finished\\nOTTO_STATUS:DONE\\n'",
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      id: agentID
    )

    let first = try await firstValue.decode(OttoEvent.self)
    let second = try await secondValue.decode(OttoEvent.self)
    #expect(first.type == .agentRunCompleted)
    #expect(first.nodeID == agentID)
    #expect(first.sequence == second.sequence)
    #expect(first.id == second.id)
  }

  @Test("Agent resume reuses a captured provider session and stable node ID")
  func agentResume() async throws {
    let supervisor = AgentSupervisor()
    let agentID = UUID()
    _ = try await supervisor.spawn(
      provider: .codex,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"session-fixture\"}' '{\"type\":\"turn.started\"}' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Original\"}}' '{\"type\":\"turn.completed\"}'",
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      id: agentID,
      parser: .codex(CodexOutputParser())
    )
    try await waitForExit(agentID: agentID, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: agentID).providerSessionID == "session-fixture")

    let registry = ToolRegistry()
    try await registry.register(
      AgentResumeTool(
        supervisor: supervisor,
        workspacePath: FileManager.default.currentDirectoryPath,
        worktreeSessions: WorktreeSessionStore(),
        adapters: [ScriptedResumeAdapter()]
      ))
    let resumed = try await registry.call(
      name: "agent.resume",
      input: try JSONValue.encode(
        AgentResumeInput(agentID: agentID, prompt: "Continue the review")),
      context: ToolContext(actorID: "resume-test", scopes: [.agentControl])
    ).decode(AgentStatusOutput.self)
    #expect(resumed.agentID == agentID)

    try await waitForState(.done, agentID: agentID, supervisor: supervisor)
    let final = try await supervisor.snapshot(agentID: agentID)
    #expect(final.id == agentID)
    #expect(final.providerSessionID == "session-fixture")
    #expect(final.result == "Resumed Continue the review")
  }

  @Test("Resume revives a persisted session after the runtime was lost")
  func agentResumeAfterRestart() async throws {
    let canvas = OttoCanvas(name: "Revive")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let nodeID: UUID = try await MainActor.run {
      let receipt = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
      guard let id = receipt.affectedNodeIDs.first else {
        throw RuntimeError.launchFailed("node creation failed")
      }
      store.dispatch(
        .setAgentDefinition(
          id: id,
          definition: AgentDefinition(
            provider: .codex,
            workingDirectory: FileManager.default.currentDirectoryPath,
            launchCommand: "codex",
            permissionMode: "workspaceWrite",
            resumeSessionID: "session-fixture"
          )))
      return id
    }

    // A fresh supervisor models the app restarting: the node persists, the runtime is gone.
    let supervisor = AgentSupervisor()
    let tool = AgentResumeTool(
      supervisor: supervisor,
      store: store,
      workspacePath: FileManager.default.currentDirectoryPath,
      worktreeSessions: WorktreeSessionStore(),
      adapters: [ScriptedResumeAdapter()]
    )
    let revived = try await tool.call(
      AgentResumeInput(agentID: nodeID, prompt: "Continue the review"),
      context: ToolContext(
        actorID: "revive-test", scopes: [.agentControl], source: .userInterface)
    )
    #expect(revived.agentID == nodeID)
    try await waitForState(.done, agentID: nodeID, supervisor: supervisor)
    let final = try await supervisor.snapshot(agentID: nodeID)
    #expect(final.result == "Resumed Continue the review")
    #expect(final.providerSessionID == "session-fixture")
  }

  @Test("Sending a follow-up to a completed provider run continues its session")
  func agentSendPromptContinuesCompletedRun() async throws {
    let supervisor = AgentSupervisor()
    let agentID = UUID()
    _ = try await supervisor.spawn(
      provider: .codex,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"session-fixture\"}' '{\"type\":\"turn.started\"}' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Original\"}}' '{\"type\":\"turn.completed\"}'",
        ],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      id: agentID,
      parser: .codex(CodexOutputParser())
    )
    try await waitForExit(agentID: agentID, supervisor: supervisor)

    let tool = AgentSendPromptTool(
      supervisor: supervisor,
      workspacePath: FileManager.default.currentDirectoryPath,
      worktreeSessions: WorktreeSessionStore(),
      adapters: [ScriptedResumeAdapter()]
    )
    let continued = try await tool.call(
      AgentPromptInput(agentID: agentID, prompt: "Continue the review"),
      context: ToolContext(actorID: "follow-up-test", scopes: [.agentControl])
    )
    #expect(continued.agentID == agentID)

    try await waitForState(.done, agentID: agentID, supervisor: supervisor)
    let final = try await supervisor.snapshot(agentID: agentID)
    #expect(final.id == agentID)
    #expect(final.providerSessionID == "session-fixture")
    #expect(final.result == "Resumed Continue the review")
  }

  @Test("Agent-initiated delegation is throttled; human callers never are")
  func agentControlThrottleBoundsAgents() async throws {
    let throttle = AgentControlThrottle(
      spawnLimit: .init(maxCalls: 2, window: .seconds(60)),
      promptLimit: .init(maxCalls: 2, window: .seconds(60))
    )
    let agentContext = ToolContext(
      actorID: "otto-agent-fixture", scopes: [.agentControl], source: .agent)
    let humanContext = ToolContext(
      actorID: "otto-app", scopes: [.agentControl], source: .userInterface)

    try await throttle.authorizeSpawn(agentContext)
    try await throttle.authorizeSpawn(agentContext)
    await #expect(throws: ToolRegistryError.self) {
      try await throttle.authorizeSpawn(agentContext)
    }
    // Prompt budget is independent of the spawn budget.
    try await throttle.authorizePrompt(agentContext)
    try await throttle.authorizePrompt(agentContext)
    await #expect(throws: ToolRegistryError.self) {
      try await throttle.authorizePrompt(agentContext)
    }
    // Human and system callers bypass the throttle entirely.
    for _ in 0..<10 {
      try await throttle.authorizeSpawn(humanContext)
      try await throttle.authorizePrompt(humanContext)
    }
  }

  @Test("A chat prompt to an interactive provider swaps to a structured run without TUI paint")
  func chatPromptSwapsInteractiveToStructured() async throws {
    let supervisor = AgentSupervisor()
    let agentID = UUID()
    let adapter = ChatSwapAdapter()
    _ = try await supervisor.spawnInteractive(
      adapter: adapter,
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite
      ),
      id: agentID
    )
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if try await supervisor.snapshot(agentID: agentID).output.contains("/skills") { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let tool = AgentSendPromptTool(
      supervisor: supervisor,
      workspacePath: FileManager.default.currentDirectoryPath,
      worktreeSessions: WorktreeSessionStore(),
      adapters: [adapter]
    )
    _ = try await tool.call(
      AgentPromptInput(agentID: agentID, prompt: "hello"),
      context: ToolContext(actorID: "chat-swap", scopes: [.agentControl])
    )
    try await waitForState(.done, agentID: agentID, supervisor: supervisor)

    let final = try await supervisor.snapshot(agentID: agentID)
    #expect(final.executionMode == .oneShotProvider)
    #expect(final.transcript.contains { $0.role == .user && $0.text == "hello" })
    #expect(final.transcript.last?.role == .assistant)
    #expect(final.transcript.last?.text == "Structured hello")
    // Terminal paint from the replaced interactive harness must never leak into chat.
    #expect(!final.transcript.contains { $0.text.contains("/skills") })
  }

  @Test("Resource catalogue shares one deterministic state path")
  func spatialCatalogue() async throws {
    let canvas = OttoCanvas(name: "Catalogue")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let context = ToolContext(actorID: "catalogue-e2e", scopes: [.canvasRead, .canvasWrite])
    let first = try await registry.call(
      name: "node.create",
      input: try JSONValue.encode(NodeCreateInput(kind: .markdown, x: -200, y: -100)),
      context: context
    ).decode(NodeCreateOutput.self).node
    let second = try await registry.call(
      name: "node.create",
      input: try JSONValue.encode(NodeCreateInput(kind: .browser, x: 400, y: 200)),
      context: context
    ).decode(NodeCreateOutput.self).node

    let focused = try await registry.call(
      name: "node.focus",
      input: try JSONValue.encode(NodeIDInput(nodeID: first.id)),
      context: context
    ).decode(OttoNode.self)
    #expect(focused.id == first.id)
    #expect(await store.activeCanvas.selectedNodeID == first.id)
    #expect(
      try await registry.call(
        name: "node.list", input: .object([:]), context: context
      ).decode([OttoNode].self).count == 2)
    #expect(
      try await registry.call(
        name: "node.get",
        input: try JSONValue.encode(NodeIDInput(nodeID: first.id)),
        context: context
      ).decode(OttoNode.self).id == first.id)

    _ = await store.dispatch(.setNodePresentation(id: second.id, presentation: .compact))
    #expect(
      await store.activeCanvas.nodes.first(where: { $0.id == second.id })?
        .effectivePresentationMode == .compact)

    await #expect(throws: ToolRegistryError.self) {
      try await registry.call(
        name: "node.get",
        input: try JSONValue.encode(NodeIDInput(nodeID: UUID())),
        context: context
      )
    }
  }

  @Test(
    "Provider launches preserve standalone or delegated session ownership",
    arguments: [false, true])
  func providerSpawn(delegated: Bool) async throws {
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-non-git-provider-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = OttoCanvas(name: "Provider launch")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: supervisor,
      workspacePath: workspace.path
    )
    let parentID: UUID?
    if delegated {
      parentID = await store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first
    } else {
      parentID = nil
    }
    let context = ToolContext(
      actorID: "provider-e2e",
      scopes: [.canvasWrite, .agentRead, .agentControl],
      source: delegated ? .agent : .system,
      sourceNodeID: parentID,
      sourceCanvasID: canvas.id
    )

    let providers = try await registry.call(
      name: "agent.providers",
      input: .object([:]),
      context: context
    ).decode([AgentProviderInfo].self)
    #expect(providers.first(where: { $0.provider == .shell })?.installed == true)

    let spawned = try await registry.call(
      name: "agent.spawn",
      input: try JSONValue.encode(
        AgentSpawnProviderInput(
          provider: .shell,
          prompt: "printf 'OTTO_RESULT:Shell adapter ok\\nOTTO_STATUS:DONE\\n'",
          x: 10,
          y: 20
        )),
      context: context
    ).decode(AgentSpawnOutput.self)
    try await waitForState(.done, agentID: spawned.agentID, supervisor: supervisor)

    let result = try await registry.call(
      name: "agent.get_result",
      input: try JSONValue.encode(AgentStatusInput(agentID: spawned.agentID)),
      context: context
    ).decode(AgentStatusOutput.self)
    #expect(result.result == "Shell adapter ok")
    #expect(result.boundedOutput.contains("OTTO_STATUS:DONE"))
    let saved = await store.snapshot
    let restored = try JSONDecoder().decode(
      WorkspaceSnapshot.self, from: JSONEncoder().encode(saved))
    let restoredCanvas = try #require(restored.canvases.first)
    let child = try #require(restoredCanvas.nodes.first(where: { $0.id == spawned.agentID }))
    #expect(child.content == .agent(provider: .shell))
    #expect(child.parentAgentID == parentID)
    #expect(child.isStandaloneAgent == !delegated)
    #expect(saved.canvases.first?.selectedNodeID == parentID)
    #expect(restoredCanvas.selectedNodeID == parentID)
    #expect(restoredCanvas.nodes.filter(\.isStandaloneAgent).count == 1)
  }

  @Test("Authenticated coding providers complete through production adapters")
  func authenticatedCodingProviders() async throws {
    guard ProcessInfo.processInfo.environment["OTTO_PROVIDER_E2E"] == "1" else { return }

    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-provider-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let canvas = OttoCanvas(name: "Authenticated provider E2E")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: supervisor,
      workspacePath: workspace.path
    )
    let context = ToolContext(
      actorID: "authenticated-provider-e2e",
      scopes: [.canvasWrite, .agentRead, .agentControl]
    )

    do {
      for (provider, marker) in [
        (AgentProvider.claudeCode, "OTTO_CLAUDE_E2E_OK"),
        (AgentProvider.codex, "OTTO_CODEX_E2E_OK"),
      ] {
        let spawned = try await registry.call(
          name: "agent.spawn",
          input: try JSONValue.encode(
            AgentSpawnProviderInput(
              provider: provider,
              prompt: "Reply with exactly \(marker) and do not use tools.",
              x: 0,
              y: 0,
              permissionMode: .readOnly,
              isolatedWorktree: false
            )),
          context: context
        ).decode(AgentSpawnOutput.self)

        let completed = try await waitForProviderCompletion(
          agentID: spawned.agentID,
          supervisor: supervisor
        )
        #expect(completed.exitCode == 0)
        #expect(completed.state == .done)
        #expect(completed.providerSessionID?.isEmpty == false)

        let result = try await registry.call(
          name: "agent.get_result",
          input: try JSONValue.encode(AgentStatusInput(agentID: spawned.agentID)),
          context: context
        ).decode(AgentStatusOutput.self)
        #expect(result.result?.contains(marker) == true)

        let sessionID = try #require(completed.providerSessionID)
        let resumeMarker = "\(marker)_RESUMED"
        _ = try await registry.call(
          name: "agent.resume",
          input: try JSONValue.encode(
            AgentResumeInput(
              agentID: spawned.agentID,
              prompt: "Reply with exactly \(resumeMarker) and do not use tools.",
              permissionMode: .readOnly
            )),
          context: context
        )
        let resumed = try await waitForProviderCompletion(
          agentID: spawned.agentID,
          supervisor: supervisor
        )
        #expect(resumed.exitCode == 0)
        #expect(resumed.state == .done)
        #expect(resumed.providerSessionID == sessionID)
        #expect(resumed.result?.contains(resumeMarker) == true)
      }

      #expect(await supervisor.activeProcessIDs().isEmpty)
      #expect(try relativeFilePaths(in: workspace).isEmpty)
    } catch {
      await supervisor.stopAll()
      throw error
    }
    await supervisor.stopAll()
  }

  @Test("A supervised background command survives its parent turn and can be waited on later")
  func terminalSurvivesParentTurn() async throws {
    let workspace = FileManager.default.temporaryDirectory.appending(
      path: "otto-background-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = OttoCanvas(name: "Background lifetime")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: supervisor, workspacePath: workspace.path)
    let parent = await store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
      .affectedNodeIDs[0]
    do {
      _ = try await supervisor.spawnOneShot(
        adapter: ShellAdapter(executablePath: "/bin/sh"),
        request: AgentLaunchRequest(
          workspacePath: workspace.path,
          prompt: "while [ ! -f parent-done ]; do sleep 0.02; done; printf 'OTTO_STATUS:DONE\\n'"),
        id: parent, canvasID: canvas.id)
      let context = ToolContext(
        actorID: "background-test", scopes: [.canvasRead, .canvasWrite, .terminalControl],
        confirmed: true,
        source: .agent, sourceNodeID: parent, sourceCanvasID: canvas.id)
      let run = try await registry.call(
        name: "terminal.run",
        input: try JSONValue.encode(
          TerminalRunInput(
            command:
              "while [ ! -f release-command ]; do sleep 0.02; done; printf 'background-complete\\n'",
            x: 0, y: 0, shell: "/bin/sh")), context: context
      ).decode(TerminalOutput.self)
      try Data().write(to: workspace.appending(path: "parent-done"))
      try await waitForState(.done, agentID: parent, supervisor: supervisor)
      let deadline = ContinuousClock.now + .seconds(5)
      while try await supervisor.snapshot(agentID: parent).exitCode == nil,
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(try await supervisor.snapshot(agentID: parent).exitCode == 0)
      let pending = try await registry.call(
        name: "terminal.wait",
        input: try JSONValue.encode(
          TerminalWaitInput(terminalID: run.terminalID, timeoutMilliseconds: 1)), context: context
      ).decode(TerminalOutput.self)
      #expect(pending.state == .working)
      #expect(pending.exitCode == nil)
      try Data().write(to: workspace.appending(path: "release-command"))
      let completed = try await registry.call(
        name: "terminal.wait",
        input: try JSONValue.encode(
          TerminalWaitInput(terminalID: run.terminalID, timeoutMilliseconds: 5_000)),
        context: context
      ).decode(TerminalOutput.self)
      #expect(completed.state == .done)
      #expect(completed.exitCode == 0)
      #expect(completed.boundedOutput.contains("background-complete"))
      await supervisor.stopAll()
    } catch {
      await supervisor.stopAll()
      throw error
    }
  }

  @Test("Terminal tools run commands and control an interactive shell end to end")
  func terminalLifecycle() async throws {
    let canvas = OttoCanvas(name: "Terminal control")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: supervisor
    )
    let context = ToolContext(
      actorID: "terminal-e2e",
      scopes: [.canvasRead, .canvasWrite, .terminalControl], confirmed: true
    )

    let run = try await registry.call(
      name: "terminal.run",
      input: try JSONValue.encode(
        TerminalRunInput(
          // Long enough to still be running at the 1 ms wait below, even on a loaded CI runner.
          command: "sleep 1; printf 'terminal-run-ok\\n'",
          x: 20,
          y: 30,
          shell: "/bin/sh"
        )),
      context: context
    ).decode(TerminalOutput.self)
    let stillRunning = try await registry.call(
      name: "terminal.wait",
      input: try JSONValue.encode(
        TerminalWaitInput(terminalID: run.terminalID, timeoutMilliseconds: 1)),
      context: context
    ).decode(TerminalOutput.self)
    #expect(stillRunning.state == .working)
    #expect(stillRunning.exitCode == nil)

    let waited = try await registry.call(
      name: "terminal.wait",
      input: try JSONValue.encode(
        TerminalWaitInput(terminalID: run.terminalID, timeoutMilliseconds: 5_000)),
      context: context
    ).decode(TerminalOutput.self)
    #expect(waited.state == .done)
    #expect(waited.exitCode == 0)
    #expect(waited.boundedOutput.contains("terminal-run-ok"))

    let completed = try await registry.call(
      name: "terminal.read_output",
      input: try JSONValue.encode(TerminalIDInput(terminalID: run.terminalID)),
      context: context
    ).decode(TerminalOutput.self)
    #expect(completed.exitCode == 0)
    #expect(completed.boundedOutput.contains("terminal-run-ok"))

    let opened = try await registry.call(
      name: "terminal.open",
      input: try JSONValue.encode(TerminalOpenInput(x: 60, y: 70, shell: "/bin/sh")),
      context: context
    ).decode(TerminalOutput.self)
    _ = try await registry.call(
      name: "terminal.resize",
      input: try JSONValue.encode(
        TerminalResizeInput(terminalID: opened.terminalID, columns: 101, rows: 31)
      ),
      context: context
    )
    _ = try await registry.call(
      name: "terminal.send_bytes",
      input: try JSONValue.encode(
        TerminalBytesInput(
          terminalID: opened.terminalID,
          data: Data("printf 'interactive-ok\\n'\\n".utf8)
        )),
      context: context
    )
    let interactive = try await waitForOutput(
      "interactive-ok",
      terminalID: opened.terminalID,
      registry: registry,
      context: context
    )
    #expect(interactive.state == .working)

    let stopped = try await registry.call(
      name: "terminal.stop_process",
      input: try JSONValue.encode(TerminalIDInput(terminalID: opened.terminalID)),
      context: context
    ).decode(TerminalOutput.self)
    #expect(stopped.state == .stopped)
    #expect(await store.activeCanvas.nodes.count == 2)
    #expect(
      await store.activeCanvas.nodes.allSatisfy {
        if case .terminal(shell: "/bin/sh") = $0.content { return true }
        return false
      })
  }

  @Test("Editing agent launches in an isolated worktree with safe diff and cleanup")
  func isolatedAgentWorktree() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-agent-worktree-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runGitCommand(["init"], at: root)
    try runGitCommand(["config", "user.email", "otto@example.invalid"], at: root)
    try runGitCommand(["config", "user.name", "Otto Tests"], at: root)
    try Data("baseline\n".utf8).write(to: root.appending(path: "README.md"))
    try Data(".otto/\nworktrees/\n".utf8).write(to: root.appending(path: ".gitignore"))
    try runGitCommand(["add", "README.md", ".gitignore"], at: root)
    try runGitCommand(["commit", "-m", "baseline"], at: root)

    let canvas = OttoCanvas(name: "Isolated agent")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let manager = GitWorktreeManager(
      repositoryPath: root.path,
      worktreeRootPath: root.appending(path: "worktrees").path
    )
    let sessions = WorktreeSessionStore()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      workspacePath: root.path,
      worktrees: manager,
      worktreeSessions: sessions
    )
    let context = ToolContext(
      actorID: "worktree-e2e",
      scopes: [.canvasWrite, .agentRead, .agentControl, .globalDestructive],
      confirmed: true
    )
    let direct = try await registry.call(
      name: "agent.spawn",
      input: try JSONValue.encode(
        AgentSpawnProviderInput(
          provider: .shell,
          prompt: "printf 'OTTO_RESULT:Direct ok\\nOTTO_STATUS:DONE\\n'",
          x: -100,
          y: 0
        )),
      context: context
    ).decode(AgentSpawnOutput.self)
    #expect(direct.worktreePath == nil)
    #expect(direct.branch == nil)

    let spawned = try await registry.call(
      name: "agent.spawn",
      input: try JSONValue.encode(
        AgentSpawnProviderInput(
          provider: .shell,
          prompt: "printf 'OTTO_RESULT:Isolated ok\\nOTTO_STATUS:DONE\\n'",
          x: 0,
          y: 0,
          isolatedWorktree: true
        )),
      context: context
    ).decode(AgentSpawnOutput.self)
    let worktreePath = try #require(spawned.worktreePath)
    #expect(spawned.branch?.hasPrefix("otto/") == true)
    #expect(FileManager.default.fileExists(atPath: worktreePath))

    try Data("changed\n".utf8).write(
      to: URL(fileURLWithPath: worktreePath).appending(path: "README.md"))
    let status = try await registry.call(
      name: "worktree.status",
      input: try JSONValue.encode(WorktreeNodeInput(nodeID: spawned.agentID)),
      context: context
    ).decode(WorktreeStatus.self)
    #expect(status.dirty)
    #expect(status.changedFiles == 1)

    await #expect(throws: WorktreeError.self) {
      try await registry.call(
        name: "worktree.cleanup",
        input: try JSONValue.encode(WorktreeNodeInput(nodeID: spawned.agentID)),
        context: context
      )
    }
    #expect(FileManager.default.fileExists(atPath: worktreePath))

    try runGitCommand(["add", "README.md"], at: URL(fileURLWithPath: worktreePath))
    try runGitCommand(
      ["commit", "-m", "agent worktree change"], at: URL(fileURLWithPath: worktreePath))
    let agentContext = ToolContext(
      actorID: "isolated-agent",
      scopes: [.agentControl],
      source: .agent,
      sourceNodeID: spawned.agentID,
      sourceCanvasID: canvas.id
    )
    let integrated = try await registry.call(
      name: "worktree.integrate",
      input: try JSONValue.encode(WorktreeNodeInput(nodeID: spawned.agentID)),
      context: agentContext
    ).decode(WorktreeIntegrateOutput.self)
    #expect(integrated.commits.count == 1)
    #expect(integrated.repositoryHead.count == 40)
    #expect(
      try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        == "changed\n")

    _ = try await registry.call(
      name: "worktree.cleanup",
      input: try JSONValue.encode(WorktreeNodeInput(nodeID: spawned.agentID)),
      context: context
    )
    #expect(!FileManager.default.fileExists(atPath: worktreePath))
  }
}

private func runGitCommand(_ arguments: [String], at directory: URL) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-C", directory.path] + arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw RuntimeError.launchFailed(
      "Git fixture command failed: \(arguments.joined(separator: " "))")
  }
}

private func waitForState(
  _ expected: AgentLifecycleState,
  agentID: UUID,
  supervisor: AgentSupervisor
) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if try await supervisor.snapshot(agentID: agentID).state == expected { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RuntimeError.launchFailed("Timed out waiting for \(expected.rawValue)")
}

private func waitForOutput(
  _ marker: String,
  terminalID: UUID,
  registry: ToolRegistry,
  context: ToolContext
) async throws -> TerminalOutput {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    let output = try await registry.call(
      name: "terminal.read_output",
      input: try JSONValue.encode(TerminalIDInput(terminalID: terminalID)),
      context: context
    ).decode(TerminalOutput.self)
    if output.boundedOutput.contains(marker) { return output }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RuntimeError.launchFailed("Timed out waiting for terminal output: \(marker)")
}

private func waitForChildPID(
  terminalID: UUID,
  supervisor: AgentSupervisor
) async throws -> pid_t {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    let output = try await supervisor.snapshot(agentID: terminalID).output
    if let marker = output.range(of: "child="),
      let end = output[marker.upperBound...].firstIndex(where: { !$0.isNumber }),
      let pid = pid_t(output[marker.upperBound..<end])
    {
      return pid
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RuntimeError.launchFailed("Timed out waiting for child process identifier")
}

private func waitForExit(agentID: UUID, supervisor: AgentSupervisor) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if try await supervisor.snapshot(agentID: agentID).exitCode != nil { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RuntimeError.launchFailed("Timed out waiting for agent process exit")
}

private func waitForProviderCompletion(
  agentID: UUID,
  supervisor: AgentSupervisor
) async throws -> AgentRuntimeSnapshot {
  let deadline = ContinuousClock.now + .seconds(180)
  while ContinuousClock.now < deadline {
    let snapshot = try await supervisor.snapshot(agentID: agentID)
    if snapshot.exitCode != nil { return snapshot }
    try await Task.sleep(for: .milliseconds(100))
  }
  throw RuntimeError.launchFailed("Timed out waiting for authenticated provider completion")
}

private func relativeFilePaths(in directory: URL) throws -> [String] {
  guard
    let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [],
      errorHandler: { _, _ in false }
    )
  else { return [] }
  return enumerator.compactMap { item in
    guard let url = item as? URL else { return nil }
    return String(url.path.dropFirst(directory.path.count + 1))
  }.sorted()
}

private func waitForProcessToExit(_ pid: pid_t) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    errno = 0
    if kill(pid, 0) == -1, errno == ESRCH { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RuntimeError.launchFailed("Process \(pid) remained alive after its node closed")
}

private func waitForState(
  _ expected: AgentLifecycleState,
  agentID: UUID,
  client: ControlClient
) async throws -> AgentStatusOutput {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    let value = try await client.callAsync(
      "agent.get_status",
      arguments: try JSONValue.encode(AgentStatusInput(agentID: agentID))
    )
    let status = try value.decode(AgentStatusOutput.self)
    if status.state == expected { return status }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw RuntimeError.launchFailed("Timed out waiting for \(expected.rawValue)")
}

private struct ScriptedResumeAdapter: AgentAdapter {
  let provider = AgentProvider.codex

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard request.resumeSessionID == "session-fixture", let prompt = request.prompt else {
      throw RuntimeError.launchFailed("Resume request did not preserve its provider session")
    }
    let message = "Resumed \(prompt)"
    let script =
      "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"session-fixture\"}' '{\"type\":\"turn.started\"}' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(message)\"}}' '{\"type\":\"turn.completed\"}'"
    return ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: ["-c", script],
      workingDirectory: request.workspacePath
    )
  }
}

/// Interactive launches paint TUI-style noise and stay resident; prompted launches emit
/// structured provider JSON — mirroring how real chat swaps the harness for a one-shot run.
private struct ChatSwapAdapter: AgentAdapter {
  let provider = AgentProvider.codex

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard let prompt = request.prompt else {
      return ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf 'Use /skills to list available skills\\n> '; sleep 30",
        ],
        workingDirectory: request.workspacePath
      )
    }
    let message = "Structured \(prompt)"
    let script =
      "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"chat-swap\"}' '{\"type\":\"turn.started\"}' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(message)\"}}' '{\"type\":\"turn.completed\"}'"
    return ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: ["-c", script],
      workingDirectory: request.workspacePath
    )
  }
}

private struct MissingProviderAdapter: AgentAdapter {
  let provider = AgentProvider.claudeCode
  func detectInstallation() async -> InstallationStatus {
    .missing(remediation: "Install the fixture provider.")
  }
  func availableModels() async -> [AgentModel] { [] }
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    throw RuntimeError.launchFailed("Fixture provider is intentionally missing")
  }
}

private struct RestartFixtureAdapter: AgentAdapter {
  let provider = AgentProvider.shell

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: ["-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"],
      workingDirectory: request.workspacePath
    )
  }
}

private struct PersistedSessionRestartAdapter: AgentAdapter {
  let provider = AgentProvider.codex

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard request.resumeSessionID == "persisted-session" else {
      throw RuntimeError.launchFailed("Persisted session was not forwarded")
    }
    return ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: ["-c", "trap 'exit 0' TERM INT; while :; do sleep 1; done"],
      workingDirectory: request.workspacePath
    )
  }
}
