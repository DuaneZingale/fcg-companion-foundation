import Foundation
import OttoModels

public struct AgentPendingPermission: Equatable, Sendable {
  public var requestID: UUID
  public var runID: UUID
  public var reason: String
  public var nonce: String
  public var requestedAt: Date
  /// The tool or app confirmation asking, such as `Website account click`.
  public var toolName: String

  public init(
    requestID: UUID,
    runID: UUID,
    reason: String,
    nonce: String,
    requestedAt: Date,
    toolName: String = ""
  ) {
    self.requestID = requestID
    self.runID = runID
    self.reason = reason
    self.nonce = nonce
    self.requestedAt = requestedAt
    self.toolName = toolName
  }
}

public actor AgentSupervisor {
  private var childObservationTasks: [UUID: Task<Void, Never>] = [:]

  private func observeCodexChildren(id: UUID, runID: UUID) {
    childObservationTasks[id]?.cancel()
    let reader = CodexChildSessionStore()
    childObservationTasks[id] = Task { [weak self] in
      while !Task.isCancelled {
        guard let context = await self?.childObservationContext(id: id, runID: runID) else {
          return
        }
        if let sessionID = context.providerSessionID {
          let children = await reader.children(parentID: sessionID, since: context.startedAt)
          await self?.mergeObservedChildren(children, id: id, runID: runID)
        }
        if context.completedAt != nil { return }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func childObservationContext(id: UUID, runID: UUID) -> AgentRuntimeSnapshot? {
    guard let agent = agents[id], agent.runID == runID else { return nil }
    return agent.snapshot
  }

  private func mergeObservedChildren(_ children: [AgentChildRun], id: UUID, runID: UUID) {
    guard var agent = agents[id], agent.runID == runID else { return }
    let previous = agent.snapshot.childRuns
    for var child in children {
      // The stream may have a newer terminal result than the file tail.
      if child.state.isActive,
        let existing = agent.snapshot.childRuns.first(where: { $0.id == child.id }),
        !existing.state.isActive
      {
        continue
      }
      if agent.snapshot.completedAt != nil, child.state.isActive {
        child.state =
          (agent.snapshot.state == .stopped || agent.snapshot.state == .interrupted)
          ? .stopped : .unknown
        child.completedAt = .now
      }
      if let index = agent.snapshot.childRuns.firstIndex(where: { $0.id == child.id }) {
        agent.snapshot.childRuns[index] = child
      } else {
        agent.snapshot.childRuns.append(child)
      }
    }
    guard previous != agent.snapshot.childRuns else { return }
    agents[id] = agent
    refreshDelegatingParent(id)
    eventContinuation.yield(.transcriptChanged(agentID: id))
  }

  private struct DelegatedChild {
    let parentID: UUID
    let parentRunID: UUID?
    let name: String
    let kind: String
  }
  private var delegatedChildren: [UUID: DelegatedChild] = [:]

  /// Associates a Otto-tool spawn with the requesting turn, regardless of its provider.
  public func registerDelegatedChild(
    parentID: UUID, childID: UUID, name: String, kind: String = "agent"
  ) {
    guard parentID != childID, let parent = agents[parentID], agents[childID] != nil else { return }
    delegatedChildren[childID] = DelegatedChild(
      parentID: parentID, parentRunID: parent.snapshot.runID, name: name, kind: kind)
    refreshDelegatingParent(childID)
  }

  private func refreshDelegatingParent(_ childID: UUID) {
    guard let relation = delegatedChildren[childID], let parent = agents[relation.parentID],
      relation.parentRunID == parent.snapshot.runID
    else { return }
    // Refresh the projected activity without inventing a lifecycle transition. The parent
    // must update even while blocked inside event.wait.
    eventContinuation.yield(.transcriptChanged(agentID: relation.parentID))
  }

  private func projectedSnapshot(_ snapshot: AgentRuntimeSnapshot) -> AgentRuntimeSnapshot {
    var result = snapshot
    for (id, relation) in delegatedChildren.sorted(by: { $0.key.uuidString < $1.key.uuidString })
    where relation.parentID == snapshot.id && relation.parentRunID == snapshot.runID {
      guard let source = agents[id]?.snapshot else { continue }
      let state: AgentChildRunState
      switch source.state {
      case .created, .starting: state = .starting
      case .working: state = .working
      case .idle, .waitingUser, .waitingPermission: state = .waiting
      case .done: state = .done
      case .failed: state = .failed
      case .stopped, .interrupted: state = .stopped
      }
      let activity = source.transcript.filter { $0.kind == .toolCall }.suffix(40)
      var child = AgentChildRun(
        id: id.uuidString, name: relation.name,
        activity: source.result ?? activity.last?.text ?? source.lastPrompt ?? state.rawValue,
        state: state, startedAt: source.startedAt, completedAt: source.completedAt,
        toolCount: source.transcript.filter { $0.kind == .toolCall }.count)
      child.task = source.lastPrompt
      child.kind = relation.kind
      child.activityLog =
        relation.kind == "command"
        ? [TerminalOutputSearch.sanitizedExcerpt(source.output, limit: 2_000)]
        : activity.map(\.text)
      result.childRuns.append(child)
    }
    return result
  }

  private struct ManagedAgent {
    let runID: UUID
    var snapshot: AgentRuntimeSnapshot
    let process: PTYProcess
    var pendingText: String
    var scrollback: TerminalScrollbackRing
    var parser: ProviderParser
    let successfulExitState: AgentLifecycleState
    var outputEnded: Bool
    var pendingExitCode: Int32?
    var promptTextFilter = InteractiveTextFilter()
    var promptScanBuffer: String
    var activeInteractivePrompt: String?
    var confirmedWorkspaceTrust: Bool
    /// Set when workspace trust was answered before the trust screen's navigation footer was
    /// read. That footer still arrives afterwards and must not be mistaken for a new prompt.
    var trustFooterPending = false
    var bypassProviderPermissions = false
    let scheduledWorker: Bool
    /// Where the process runs, kept for harvesting the provider's on-disk session records.
    let workingDirectory: String
    /// How many harvested session turns are already merged into the transcript; a cursor so
    /// repeated harvests of the same growing session file never duplicate turns.
    var harvestedTurnCount: Int
    /// Team-room turns execute through the bot's provider session so identity and durable memory
    /// remain available, but their transcript belongs to the room rather than this private chat.
    var hiddenTurnActive: Bool
    var hiddenTurnTranscript: [AgentTranscriptEntry]
  }

  /// One blocked provider tool approval. The continuation parks the control-socket handler that
  /// carried the request until the user answers in the conversation surface.
  private struct PendingPermission {
    let id: UUID
    let toolName: String
    let reason: String
    let nonce: String
    let isBypassEligible: Bool
    let requestedAt: Date
    let continuation: CheckedContinuation<Bool, any Error>
    let timeoutTask: Task<Void, Never>?
  }

  /// One blocked agent question. A nil continuation marks a provider-native prompt (Hermes
  /// clarify) whose answer travels back through the process's stdin; a non-nil continuation
  /// parks the `agent.ask_user` tool call that carried it until the user answers.
  private struct PendingChoice {
    var prompt: AgentChoicePrompt
    let continuation: CheckedContinuation<String, Never>?
    /// Set when the question came from a provider TUI rather than a tool call. The answer has to
    /// be delivered as cursor keys against the live menu, not written as a line of text.
    var menu: InteractiveMenu?

    init(
      prompt: AgentChoicePrompt,
      continuation: CheckedContinuation<String, Never>?,
      menu: InteractiveMenu? = nil
    ) {
      self.prompt = prompt
      self.continuation = continuation
      self.menu = menu
    }
  }

  private var agents: [UUID: ManagedAgent] = [:]
  private var runHistory: [UUID: [AgentRunRecord]] = [:]
  private var controlPlane: AgentControlPlane?
  private var bootstrapProvider:
    (@Sendable (UUID, AgentPermissionMode) async -> AgentBootstrapPacket?)?
  private var interactiveCompletionTasks: [UUID: Task<Void, Never>] = [:]
  /// One pending "has this command gone quiet at a prompt?" check per command terminal.
  private var terminalQuietTasks: [UUID: Task<Void, Never>] = [:]
  private var terminalInputQuietInterval = TerminalInputWaitDetector.quietInterval
  private var pendingPermissions: [UUID: [PendingPermission]] = [:]
  private var pendingChoices: [UUID: [PendingChoice]] = [:]
  private let scrollbackCapacity: Int
  private let historyLimit: Int
  private let historyOutputCapacity: Int
  public nonisolated let eventBus: OttoEventBus
  public nonisolated let resourceScheduler: AgentResourceScheduler
  private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
  public nonisolated let events: AsyncStream<RuntimeEvent>

  public init(
    scrollbackCapacity: Int = 1_048_576,
    historyLimit: Int = 20,
    historyOutputCapacity: Int = 262_144,
    resourceScheduler: AgentResourceScheduler = AgentResourceScheduler(),
    eventBus: OttoEventBus = OttoEventBus()
  ) {
    self.scrollbackCapacity = max(1, scrollbackCapacity)
    self.historyLimit = max(1, historyLimit)
    self.historyOutputCapacity = max(1, historyOutputCapacity)
    self.resourceScheduler = resourceScheduler
    self.eventBus = eventBus
    var continuation: AsyncStream<RuntimeEvent>.Continuation!
    self.events = AsyncStream { continuation = $0 }
    self.eventContinuation = continuation
  }

  public func spawn(
    provider: AgentProvider,
    specification: ProcessLaunchSpec,
    id: UUID = UUID(),
    parser: ProviderParser = .markers,
    initialState: AgentLifecycleState = .starting,
    successfulExitState: AgentLifecycleState = .stopped,
    executionMode: AgentExecutionMode = .oneShotProvider,
    scheduledWorker: Bool = false,
    permissionMode: AgentPermissionMode = .workspaceWrite
  ) throws -> UUID {
    let previousTranscript = agents[id]?.snapshot.transcript ?? []
    if let previous = agents[id], previous.snapshot.completedAt != nil {
      archive(previous)
    }
    denyPendingPermissions(agentID: id)
    cancelPendingChoices(agentID: id)
    let process = try PTYProcess.spawn(specification)
    let runID = UUID()
    var snapshot = AgentRuntimeSnapshot(
      id: id,
      runID: runID,
      provider: provider,
      executionMode: executionMode,
      state: .starting,
      confidence: 1,
      transcript: previousTranscript
    )
    snapshot.processID = process.processIdentifier
    agents[id] = ManagedAgent(
      runID: runID,
      snapshot: snapshot,
      process: process,
      pendingText: "",
      scrollback: TerminalScrollbackRing(capacity: scrollbackCapacity),
      parser: parser,
      successfulExitState: successfulExitState,
      outputEnded: false,
      pendingExitCode: nil,
      promptScanBuffer: "",
      activeInteractivePrompt: nil,
      confirmedWorkspaceTrust: false,
      bypassProviderPermissions: permissionMode == .unrestricted,
      scheduledWorker: scheduledWorker,
      workingDirectory: specification.workingDirectory,
      harvestedTurnCount: 0,
      hiddenTurnActive: false,
      hiddenTurnTranscript: []
    )
    eventContinuation.yield(.stateChanged(agentID: id, state: .starting, confidence: 1))
    eventBus.publish(
      OttoEvent(
        type: .agentRunStarted,
        nodeID: id,
        state: .starting,
        confidence: 1,
        runID: runID
      ))

    Task { [weak self] in
      for await data in process.output {
        await self?.ingest(data, for: id, runID: runID)
      }
      await self?.outputEnded(id: id, runID: runID)
    }
    Task { [weak self] in
      for await code in process.exit {
        await self?.processExited(id: id, runID: runID, code: code)
      }
    }
    if initialState != .starting {
      var agent = agents[id]!
      transition(&agent, to: initialState, confidence: 1)
      agents[id] = agent
      refreshDelegatingParent(id)
    }
    if provider == .codex { observeCodexChildren(id: id, runID: runID) }
    return id
  }

  /// Installs the control-plane wiring every subsequently spawned provider and terminal receives
  /// through its child environment, letting agents reach workspace tools via otto-mcp and ottoctl.
  public func setControlPlane(_ plane: AgentControlPlane?) {
    controlPlane = plane
  }

  /// Supplies the memory bootstrap packet for each provider launch. Every spawn, resume, and
  /// continuation asks this provider; the packet's hash lands on the run snapshot and the
  /// rendered text is written beside the workspace for inspection.
  public func setMemoryBootstrapProvider(
    _ provider: (@Sendable (UUID, AgentPermissionMode) async -> AgentBootstrapPacket?)?
  ) {
    bootstrapProvider = provider
  }

  private func preparedBootstrap(
    for request: AgentLaunchRequest, nodeID: UUID
  ) async -> (request: AgentLaunchRequest, hash: String?) {
    var request = request
    if let prompt = request.prompt, !PromptSubmission.isHiddenControlPrompt(prompt),
      let context = await turnContextProvider?(nodeID, prompt)
    {
      request.prompt = PromptSubmission.contextualPrompt(prompt, context: context)
    }
    guard request.memoryBootstrap == nil,
      let packet = await bootstrapProvider?(nodeID, request.permissionMode)
    else {
      return (request, nil)
    }
    request.memoryBootstrap = packet.text
    // Inside Otto's workspace even when the run starts in a project's source folder: the packet
    // carries memory and must not land in the user's repository.
    let directory = ((request.ottoWorkspacePath ?? request.workspacePath) as NSString)
      .appendingPathComponent(".otto/bootstrap")
    let path = (directory as NSString).appendingPathComponent("\(nodeID.uuidString).md")
    do {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try Data(packet.text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
      // Inspection copy only; the packet still travels with the launch request.
    }
    return (request, packet.hash)
  }

  private func recordBootstrapHash(_ hash: String?, agentID: UUID) {
    guard let hash, var agent = agents[agentID] else { return }
    agent.snapshot.bootstrapHash = hash
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
  }

  private func controlEnvironment(nodeID: UUID, canvasID: UUID?) async -> [String: String] {
    guard let controlPlane else { return [:] }
    var environment = [
      "OTTO_CONTROL_SOCKET": controlPlane.socketPath,
      "OTTO_CONTROL_TOKEN": await controlPlane.token(nodeID: nodeID, canvasID: canvasID),
      "OTTO_NODE_ID": nodeID.uuidString,
      "OTTO_WORKSPACE_ID": controlPlane.workspaceID.uuidString,
      "OTTO_CANVAS_ID": (canvasID ?? controlPlane.workspaceID).uuidString,
    ]
    if let mcpExecutable = controlPlane.mcpExecutable {
      environment["OTTO_MCP"] = mcpExecutable
    }
    return environment
  }

  /// Adapters need the control values inside the request as well: provider CLIs spawn the
  /// otto-mcp bridge with a scrubbed child environment, so the bridge's credentials must be
  /// written into the provider's MCP server configuration, not just this process's env.
  private func enriched(
    _ request: AgentLaunchRequest, controlEnvironment: [String: String] = [:]
  ) -> AgentLaunchRequest {
    var request = request
    if request.ottoMCPExecutable == nil {
      request.ottoMCPExecutable = controlPlane?.mcpExecutable
    }
    if request.controlEnvironment.isEmpty {
      request.controlEnvironment = controlEnvironment
    }
    if request.ottoReversibleTools.isEmpty {
      request.ottoReversibleTools = controlPlane?.reversibleTools ?? []
    }
    if request.ottoReadOnlyTools.isEmpty {
      request.ottoReadOnlyTools = controlPlane?.readOnlyTools ?? []
    }
    if request.ottoSelfConfirmingTools.isEmpty {
      request.ottoSelfConfirmingTools = controlPlane?.selfConfirmingTools ?? []
    }
    if request.ottoWorkspacePath == nil {
      request.ottoWorkspacePath = controlPlane?.workspacePath
    }
    return request
  }

  private func merged(
    _ specification: ProcessLaunchSpec, with environment: [String: String]
  ) -> ProcessLaunchSpec {
    var specification = specification
    specification.environment.merge(environment) { current, _ in current }
    return specification
  }

  private func withControlEnvironment(
    _ specification: ProcessLaunchSpec,
    nodeID: UUID,
    canvasID: UUID? = nil
  ) async -> ProcessLaunchSpec {
    merged(specification, with: await controlEnvironment(nodeID: nodeID, canvasID: canvasID))
  }

  public func spawnTerminal(
    shell: String,
    command: String? = nil,
    workingDirectory: String,
    id: UUID = UUID(),
    canvasID: UUID? = nil
  ) async throws -> UUID {
    try spawn(
      provider: .shell,
      specification: await withControlEnvironment(
        ProcessLaunchSpec(
          executable: shell,
          arguments: command.map { ["-lc", $0] } ?? ["-l"],
          environment: ["TERM": "xterm-256color"],
          workingDirectory: workingDirectory
        ),
        nodeID: id,
        canvasID: canvasID
      ),
      id: id,
      initialState: .working,
      successfulExitState: command == nil ? .stopped : .done,
      executionMode: .terminal
    )
  }

  public func spawnOneShot(
    adapter: any AgentAdapter,
    request: AgentLaunchRequest,
    id: UUID = UUID(),
    canvasID: UUID? = nil
  ) async throws -> UUID {
    guard request.prompt != nil else {
      throw RuntimeError.launchFailed("One-shot provider launch requires a prompt")
    }
    let controlEnv = await controlEnvironment(nodeID: id, canvasID: canvasID)
    var accountRequest = try await withAccount(request, nodeID: id, provider: adapter.provider)
    if launchAccounts[id].map({ $0 != accountRequest.account?.accountID }) ?? false {
      accountRequest.resumeSessionID = nil
    }
    recordLaunch(id, account: accountRequest.account, provider: adapter.provider)
    let prepared = await preparedBootstrap(
      for: enriched(accountRequest, controlEnvironment: controlEnv), nodeID: id)
    let specification = Self.applyingAccount(
      try await adapter.buildLaunchSpec(prepared.request), account: accountRequest.account)
    try await resourceScheduler.acquire(id)
    let spawnedID: UUID
    do {
      spawnedID = try spawn(
        provider: adapter.provider,
        specification: merged(specification, with: controlEnv),
        id: id,
        parser: .forProvider(adapter.provider),
        executionMode: .oneShotProvider,
        scheduledWorker: true,
        permissionMode: request.permissionMode
      )
    } catch {
      await resourceScheduler.release(id)
      throw error
    }
    recordBootstrapHash(prepared.hash, agentID: spawnedID)
    recordLaunchPrompt(request.prompt, agentID: spawnedID)
    return spawnedID
  }

  public func spawnInteractive(
    adapter: any AgentAdapter,
    request: AgentLaunchRequest,
    id: UUID = UUID(),
    canvasID: UUID? = nil
  ) async throws -> UUID {
    guard request.prompt == nil else {
      throw RuntimeError.launchFailed("Interactive provider launch cannot include a prompt")
    }
    let controlEnv = await controlEnvironment(nodeID: id, canvasID: canvasID)
    var accountRequest = try await withAccount(request, nodeID: id, provider: adapter.provider)
    if launchAccounts[id].map({ $0 != accountRequest.account?.accountID }) ?? false {
      accountRequest.resumeSessionID = nil
    }
    recordLaunch(id, account: accountRequest.account, provider: adapter.provider)
    let prepared = await preparedBootstrap(
      for: enriched(accountRequest, controlEnvironment: controlEnv), nodeID: id)
    let specification = Self.applyingAccount(
      try await adapter.buildLaunchSpec(prepared.request), account: accountRequest.account)
    let spawnedID = try spawn(
      provider: adapter.provider,
      specification: merged(specification, with: controlEnv),
      id: id,
      parser: .forProvider(adapter.provider),
      initialState: .idle,
      successfulExitState: .stopped,
      executionMode: .interactiveProvider,
      permissionMode: request.permissionMode
    )
    // Interactive TUIs may never emit a session-start event. Keep the exact ID used to
    // reopen the harness so disk recovery cannot adopt another node's recent session.
    agents[spawnedID]?.snapshot.providerSessionID = accountRequest.resumeSessionID
    recordBootstrapHash(prepared.hash, agentID: spawnedID)
    return spawnedID
  }

  public func resumeOneShot(
    adapter: any AgentAdapter,
    request: AgentLaunchRequest,
    sessionID: String,
    id: UUID,
    canvasID: UUID? = nil
  ) async throws -> UUID {
    let controlEnv = await controlEnvironment(nodeID: id, canvasID: canvasID)
    var resumedRequest = enriched(
      try await withAccount(request, nodeID: id, provider: adapter.provider),
      controlEnvironment: controlEnv)
    let accountID = resumedRequest.account?.accountID
    // A different account has a different provider home, so the old session does not exist
    // there: start a fresh provider session and let Otto's own context carry the thread.
    let accountChanged = launchAccounts[id].map { $0 != accountID } ?? false
    resumedRequest.resumeSessionID = accountChanged ? nil : sessionID
    recordLaunch(id, account: resumedRequest.account, provider: adapter.provider)
    let prepared = await preparedBootstrap(for: resumedRequest, nodeID: id)
    let specification = Self.applyingAccount(
      try await adapter.buildLaunchSpec(prepared.request), account: resumedRequest.account)
    let spawnedID = try spawn(
      provider: adapter.provider,
      specification: merged(specification, with: controlEnv),
      id: id,
      parser: .forProvider(adapter.provider),
      executionMode: .oneShotProvider,
      permissionMode: request.permissionMode
    )
    recordBootstrapHash(prepared.hash, agentID: spawnedID)
    recordLaunchPrompt(request.prompt, agentID: spawnedID)
    return spawnedID
  }

  private func recordLaunchPrompt(_ prompt: String?, agentID: UUID) {
    guard let prompt, var agent = agents[agentID] else { return }
    if !PromptSubmission.isHiddenControlPrompt(prompt) {
      agent.snapshot.lastPrompt = prompt
    }
    appendTranscript(.user, text: prompt, to: &agent)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
  }

  public func spawnDeterministicMock(
    id: UUID = UUID(),
    canvasID: UUID? = nil
  ) async throws -> UUID {
    // Turn context can make the submitted prompt many lines long. The mock only uses the first
    // line, but the rest must still be drained: a canonical-mode PTY holds about 1 KB of unread
    // input, and the supervisor's write would otherwise stall until it reports transportClosed.
    let script = """
      printf 'OTTO_STATUS:IDLE\\r\\n'
      IFS= read -r prompt
      stty -icanon min 0 time 2 2>/dev/null && cat >/dev/null
      printf 'OTTO_STATUS:WORKING\\r\\n'
      printf 'Working on: %s\\r\\n' "$prompt"
      sleep 0.05
      printf 'OTTO_RESULT:Completed %s\\r\\n' "$prompt"
      printf 'OTTO_STATUS:DONE\\r\\n'
      """
    return try spawn(
      provider: .shell,
      specification: await withControlEnvironment(
        ProcessLaunchSpec(
          executable: "/bin/sh",
          arguments: ["-c", script],
          environment: ["NO_COLOR": "1"],
          workingDirectory: FileManager.default.currentDirectoryPath
        ),
        nodeID: id,
        canvasID: canvasID
      ),
      id: id
    )
  }

  private var turnContextProvider: (@Sendable (UUID, String) async -> String?)?
  private var accountProvider:
    (@Sendable (UUID, AgentProvider) async throws -> AgentAccountLaunch?)?
  /// Account each node last launched on (nil = the Mac's own login). Provider sessions live in
  /// the account's provider home, so a session cannot be resumed across an account change.
  private var launchAccounts: [UUID: UUID?] = [:]
  /// The relocated provider home each node last launched with, for reading its session files.
  private var launchProviderHomes: [UUID: URL] = [:]

  private func recordLaunch(_ id: UUID, account: AgentAccountLaunch?, provider: AgentProvider) {
    launchAccounts[id] = .some(account?.accountID)
    launchProviderHomes[id] = Self.providerHome(in: account, provider: provider)
  }

  private static func providerHome(in account: AgentAccountLaunch?, provider: AgentProvider)
    -> URL?
  {
    guard let variable = ProviderAccountIsolation.descriptor(for: provider).homeVariable,
      let path = account?.environment[variable]
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  /// The provider home a node's account uses, so persisted sessions can be read back after a
  /// restart. Nil means the provider's default home (the Mac's own login).
  public func accountProviderHome(agentID: UUID, provider: AgentProvider) async -> URL? {
    guard let accountProvider,
      let account = try? await accountProvider(agentID, provider)
    else { return nil }
    return Self.providerHome(in: account, provider: provider)
  }

  /// Resolves which provider account a node's launch bills to. Called for every provider launch
  /// (spawn, interactive, resume) so account handling is uniform across providers and entry
  /// points. Throwing aborts the launch with a user-facing reason (e.g. a missing API key).
  public func setAccountProvider(
    _ provider: @escaping @Sendable (UUID, AgentProvider) async throws -> AgentAccountLaunch?
  ) {
    accountProvider = provider
  }

  private func withAccount(
    _ request: AgentLaunchRequest, nodeID: UUID, provider: AgentProvider
  ) async throws -> AgentLaunchRequest {
    guard request.account == nil, let accountProvider else { return request }
    var request = request
    request.account = try await accountProvider(nodeID, provider)
    return request
  }

  /// Account variables win over adapter defaults; Otto control variables still win overall.
  nonisolated static func applyingAccount(
    _ specification: ProcessLaunchSpec, account: AgentAccountLaunch?
  ) -> ProcessLaunchSpec {
    guard let account else { return specification }
    var specification = specification
    specification.inheritedEnvironmentPrefixesToRemove +=
      account.inheritedEnvironmentPrefixesToRemove
    specification.environment.merge(account.environment) { _, accountValue in accountValue }
    return specification
  }

  public func setTurnContextProvider(
    _ provider: @escaping @Sendable (UUID, String) async -> String?
  ) {
    turnContextProvider = provider
  }

  public func sendPrompt(agentID: UUID, prompt: String) async throws {
    let context =
      PromptSubmission.isHiddenControlPrompt(prompt)
      ? nil : await turnContextProvider?(agentID, prompt)
    let providerPrompt =
      context.map { PromptSubmission.contextualPrompt(prompt, context: $0) } ?? prompt
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    guard
      agent.snapshot.state == .idle || agent.snapshot.state == .done
        || agent.snapshot.state == .interrupted
    else {
      throw RuntimeError.invalidTransition(from: agent.snapshot.state, to: .working)
    }
    // Do not publish WORKING until the prompt has reached the provider. A process can exit in the
    // small window between the UI reading its snapshot and this write; leaving the state change in
    // front of the throwing send strands the conversation on its thinking indicator forever.
    let isHiddenTurn = PromptSubmission.isHiddenControlPrompt(prompt)
    if isHiddenTurn {
      agent.hiddenTurnActive = true
      agent.hiddenTurnTranscript.removeAll(keepingCapacity: true)
    } else {
      // A genuine one-to-one prompt begins a new visible private turn. Until this point, keep
      // swallowing late provider events from the preceding room turn: Codex can publish its
      // assistant message again after the first DONE lifecycle event.
      agent.hiddenTurnActive = false
      agent.hiddenTurnTranscript.removeAll(keepingCapacity: true)
    }
    do {
      if agent.snapshot.executionMode == .interactiveProvider {
        try submitToInteractiveEditor(providerPrompt, process: agent.process, agentID: agentID)
      } else {
        try agent.process.send(text: providerPrompt + "\n")
      }
    } catch {
      if isHiddenTurn {
        agent.hiddenTurnActive = false
        agent.hiddenTurnTranscript.removeAll(keepingCapacity: true)
      }
      throw error
    }
    agent.snapshot.runID = UUID()
    agent.snapshot.completedAt = nil
    agent.snapshot.state = .working
    agent.snapshot.confidence = 1
    agent.snapshot.result = nil
    if !PromptSubmission.isHiddenControlPrompt(prompt) {
      agent.snapshot.lastPrompt = prompt
    }
    appendTranscript(.user, text: prompt, to: &agent)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    eventBus.publish(
      OttoEvent(
        type: .agentRunStarted, nodeID: agentID,
        state: .working, confidence: 1, runID: agent.snapshot.runID))
    eventContinuation.yield(.stateChanged(agentID: agentID, state: .working, confidence: 1))
  }

  /// Returns the conversational reply produced for a hidden room turn, then clears the consumed
  /// buffer. Room-only mode deliberately remains active until the next genuine private prompt so
  /// trailing provider events cannot leak a late copy into `snapshot.transcript`.
  public func consumeHiddenTurnReply(agentID: UUID) -> String? {
    guard var agent = agents[agentID], agent.hiddenTurnActive else { return nil }
    let reply = agent.hiddenTurnTranscript.last {
      $0.role == .assistant && $0.kind == .text
    }?.text
    agent.hiddenTurnTranscript.removeAll(keepingCapacity: true)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    return reply
  }

  public func discardHiddenTurn(agentID: UUID) {
    guard var agent = agents[agentID] else { return }
    agent.hiddenTurnActive = false
    agent.hiddenTurnTranscript.removeAll(keepingCapacity: true)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
  }

  /// Adds a local control-plane message to the readable conversation without writing it to the
  /// provider PTY. Otto slash-command acknowledgements use this path so `/goal` and `/loop` are
  /// visible in the node, but can never be mistaken for model prompts.
  public func appendLocalTranscript(
    agentID: UUID,
    role: AgentTranscriptRole,
    kind: AgentTranscriptKind = .notice,
    text: String
  ) throws {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    appendTranscript(role, kind: kind, text: text, to: &agent)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    eventContinuation.yield(.transcriptChanged(agentID: agentID))
  }

  /// Prepends provider-owned history after an app restart. A resumed process may already have
  /// recorded its new prompt by the time disk restoration finishes, so retain those live entries
  /// after the restored turns and use the normal bounded/deduplicating transcript path.
  public func restoreTranscript(
    agentID: UUID,
    turns: [ProviderSessionStore.Turn]
  ) throws {
    guard !turns.isEmpty else { return }
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    let liveEntries = agent.snapshot.transcript
    agent.snapshot.transcript.removeAll(keepingCapacity: true)
    for turn in turns {
      appendTranscript(turn.role, text: turn.text, to: &agent)
    }
    for entry in liveEntries {
      appendTranscript(
        entry.role,
        kind: entry.kind,
        text: entry.text,
        detail: entry.detail,
        to: &agent
      )
    }
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    eventContinuation.yield(.transcriptChanged(agentID: agentID))
  }

  // Ink-based provider TUIs treat text that arrives in one chunk with its trailing return as a
  // paste: the text lands in the editor and the return is swallowed, so the prompt is painted
  // but never submitted. Deliver the return as its own keypress once the paste has settled.
  private func submitToInteractiveEditor(
    _ text: String,
    process: PTYProcess,
    agentID: UUID
  ) throws {
    try process.send(text: text)
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      do {
        try process.send(text: "\r")
      } catch {
        await self?.interactiveSubmissionFailed(agentID: agentID)
      }
    }
  }

  private func interactiveSubmissionFailed(agentID: UUID) {
    guard var agent = agents[agentID], agent.snapshot.state == .working else { return }
    appendTranscript(
      .activity,
      kind: .notice,
      text: "The provider closed before the prompt could be submitted.",
      to: &agent
    )
    transition(&agent, to: .failed, confidence: 1)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
  }

  public func sendInput(agentID: UUID, text: String) throws {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    if text.hasSuffix("\r") || text.hasSuffix("\n") {
      try agent.process.send(text: text)
    } else if agent.snapshot.executionMode == .interactiveProvider {
      // Native coding-agent TUIs interpret Return as carriage return, and only as its own
      // keypress — see submitToInteractiveEditor.
      try submitToInteractiveEditor(text, process: agent.process, agentID: agentID)
    } else {
      try agent.process.send(text: text + "\n")
    }
    appendTranscript(.user, text: text, to: &agent)
    if agent.snapshot.executionMode == .interactiveProvider {
      interactiveCompletionTasks[agentID]?.cancel()
      interactiveCompletionTasks[agentID] = nil
      agent.promptScanBuffer = ""
      agent.activeInteractivePrompt = nil
      agent.snapshot.attentionReason = nil
      agent.snapshot.attentionToken = nil
      agent.snapshot.result = nil
      agent.snapshot.structuredResult = nil
      agent.snapshot.completedAt = nil
      transition(&agent, to: .working, confidence: 1)
      agents[agentID] = agent
      refreshDelegatingParent(agentID)
    }
  }

  public func sendBytes(agentID: UUID, data: Data) throws {
    guard let agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    try agent.process.send(data)
  }

  public func resize(agentID: UUID, columns: UInt16, rows: UInt16) throws {
    guard let agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    try agent.process.resize(columns: columns, rows: rows)
  }

  public func interrupt(agentID: UUID, expectedRunID: UUID? = nil) throws {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    if let expectedRunID, agent.snapshot.runID != expectedRunID {
      throw RuntimeError.staleRun(expectedRunID)
    }
    interactiveCompletionTasks[agentID]?.cancel()
    interactiveCompletionTasks[agentID] = nil
    denyPendingPermissions(agentID: agentID)
    cancelPendingChoices(agentID: agentID)
    try agent.process.interrupt()
    transition(&agent, to: .interrupted, confidence: 1)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
  }

  public func stop(agentID: UUID, expectedRunID: UUID? = nil) throws {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    if let expectedRunID, agent.snapshot.runID != expectedRunID {
      throw RuntimeError.staleRun(expectedRunID)
    }
    interactiveCompletionTasks[agentID]?.cancel()
    interactiveCompletionTasks[agentID] = nil
    denyPendingPermissions(agentID: agentID)
    cancelPendingChoices(agentID: agentID)
    try agent.process.terminate()
    transition(&agent, to: .stopped, confidence: 1)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
  }

  @discardableResult
  public func stopIfPresent(agentID: UUID) throws -> Bool {
    guard var agent = agents[agentID] else { return false }
    interactiveCompletionTasks[agentID]?.cancel()
    interactiveCompletionTasks[agentID] = nil
    denyPendingPermissions(agentID: agentID)
    cancelPendingChoices(agentID: agentID)
    try agent.process.terminate()
    transition(&agent, to: .stopped, confidence: 1)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    return true
  }

  /// Parks a provider tool-permission request until the user answers it in the conversation.
  /// The agent surfaces as WAITING_PERMISSION with the tool call as its attention reason; the
  /// returned value is the user's decision. Requests queue in arrival order when a provider
  /// issues several concurrent tool calls.
  public func requestPermission(
    agentID: UUID,
    toolName: String,
    detail: String = "",
    timeout: Duration? = nil,
    isProviderPermission: Bool = false,
    detailLimit: Int = 240
  ) async throws -> Bool {
    guard let agent = agents[agentID], agent.snapshot.exitCode == nil else {
      throw RuntimeError.agentNotFound(agentID)
    }
    // Browser clicks are part of the user-selected tool bypass. Account access and other
    // explicit app confirmations remain independent of that setting.
    let isBypassEligible = isProviderPermission || toolName == "browser.click"
    if isBypassEligible && agent.bypassProviderPermissions { return true }
    let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    let reason = sanitizedAttentionReason(
      trimmedDetail.isEmpty ? "Wants to use \(toolName)" : "\(toolName): \(trimmedDetail)",
      limit: detailLimit
    )
    return try await withCheckedThrowingContinuation { continuation in
      let requestID = UUID()
      let timeoutTask = timeout.map { duration in
        Task { [weak self] in
          do { try await Task.sleep(for: duration) } catch { return }
          await self?.expirePermission(agentID: agentID, requestID: requestID)
        }
      }
      var agent = agents[agentID]!
      let wasIdle = pendingPermissions[agentID, default: []].isEmpty
      pendingPermissions[agentID, default: []].append(
        PendingPermission(
          id: requestID,
          toolName: toolName,
          reason: reason,
          nonce: UUID().uuidString.lowercased(),
          isBypassEligible: isBypassEligible,
          requestedAt: .now,
          continuation: continuation,
          timeoutTask: timeoutTask
        )
      )
      // The card answers requests in arrival order, so the reason on screen must stay the one
      // the Approve button will resolve.
      if wasIdle {
        agent.snapshot.attentionReason = reason
      }
      transition(&agent, to: .waitingPermission, confidence: 1)
      agents[agentID] = agent
      refreshDelegatingParent(agentID)
    }
  }

  /// Applies a user-selected tool policy to this run, including browser-click confirmations.
  /// Account access and other explicit app confirmations still require an answer.
  public func setProviderPermissionBypass(agentID: UUID, enabled: Bool) throws {
    guard var agent = agents[agentID], agent.snapshot.exitCode == nil else {
      throw RuntimeError.agentNotFound(agentID)
    }
    agent.bypassProviderPermissions = enabled
    let approved =
      enabled
      ? (pendingPermissions[agentID] ?? []).filter(\.isBypassEligible) : []
    if !approved.isEmpty {
      let remaining = (pendingPermissions[agentID] ?? []).filter { !$0.isBypassEligible }
      pendingPermissions[agentID] = remaining.isEmpty ? nil : remaining
      for pending in approved {
        pending.timeoutTask?.cancel()
        appendTranscript(.activity, kind: .notice, text: "Approved \(pending.reason)", to: &agent)
      }
      if let next = remaining.first {
        agent.snapshot.attentionReason = next.reason
      } else if agent.snapshot.state == .waitingPermission {
        transition(&agent, to: .working, confidence: 1)
      }
    }
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    for pending in approved { pending.continuation.resume(returning: true) }
  }

  /// Resolves the oldest pending permission request with the user's decision and returns the
  /// agent to WORKING once nothing else is waiting.
  public func resolvePermission(agentID: UUID, approved: Bool) throws {
    try resolveOldestPermission(agentID: agentID, approved: approved)
  }

  public func resolvePermission(
    agentID: UUID,
    requestID: UUID,
    nonce: String,
    approved: Bool
  ) throws {
    guard let pending = pendingPermissions[agentID]?.first,
      pending.id == requestID,
      pending.nonce == nonce
    else { throw RuntimeError.noPendingPermission(agentID) }
    try resolveOldestPermission(agentID: agentID, approved: approved)
  }

  private func resolveOldestPermission(agentID: UUID, approved: Bool) throws {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    guard var queue = pendingPermissions[agentID], !queue.isEmpty else {
      throw RuntimeError.noPendingPermission(agentID)
    }
    let pending = queue.removeFirst()
    pending.timeoutTask?.cancel()
    pendingPermissions[agentID] = queue.isEmpty ? nil : queue
    appendTranscript(
      .activity,
      kind: .notice,
      text: "\(approved ? "Approved" : "Denied") \(pending.reason)",
      to: &agent
    )
    if let next = queue.first {
      agent.snapshot.attentionReason = next.reason
      transition(&agent, to: .waitingPermission, confidence: 1)
    } else if agent.snapshot.state == .waitingPermission {
      transition(&agent, to: .working, confidence: 1)
    }
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    pending.continuation.resume(returning: approved)
  }

  private func expirePermission(agentID: UUID, requestID: UUID) {
    guard var agent = agents[agentID], var queue = pendingPermissions[agentID],
      let index = queue.firstIndex(where: { $0.id == requestID })
    else { return }
    let pending = queue.remove(at: index)
    pendingPermissions[agentID] = queue.isEmpty ? nil : queue
    appendTranscript(
      .activity, kind: .notice,
      text: "Confirmation expired: \(pending.reason). The action was not performed.", to: &agent)
    if index == 0 {
      if let next = queue.first {
        agent.snapshot.attentionReason = next.reason
        transition(&agent, to: .waitingPermission, confidence: 1)
      } else if agent.snapshot.state == .waitingPermission {
        transition(&agent, to: .working, confidence: 1)
      }
    }
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    pending.continuation.resume(throwing: RuntimeError.permissionExpired)
  }

  /// Whether the agent has a permission request awaiting a user decision.
  public func hasPendingPermission(agentID: UUID) -> Bool {
    !(pendingPermissions[agentID] ?? []).isEmpty
  }

  /// Whether an interactive run is showing a provider prompt that a keystroke answers.
  public func hasInteractivePrompt(agentID: UUID) -> Bool {
    agents[agentID]?.activeInteractivePrompt != nil
  }

  /// Clears a waiting card that no request stands behind — nothing parked, no question, no
  /// on-screen provider prompt — so Approve or Deny always leaves the run usable instead of
  /// silently doing nothing. Returns whether there was such a card to clear.
  @discardableResult
  public func dismissUnbackedAttention(agentID: UUID) throws -> Bool {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    guard [.waitingPermission, .waitingUser].contains(agent.snapshot.state),
      (pendingPermissions[agentID] ?? []).isEmpty,
      (pendingChoices[agentID] ?? []).isEmpty,
      agent.activeInteractivePrompt == nil
    else { return false }
    agent.snapshot.attentionReason = nil
    agent.snapshot.attentionToken = nil
    agent.snapshot.pendingChoice = nil
    transition(&agent, to: .idle, confidence: 0.8)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    return true
  }

  public func pendingPermission(agentID: UUID) -> AgentPendingPermission? {
    guard let agent = agents[agentID], let pending = pendingPermissions[agentID]?.first else {
      return nil
    }
    return AgentPendingPermission(
      requestID: pending.id,
      runID: agent.snapshot.runID ?? agent.runID,
      reason: pending.reason,
      nonce: pending.nonce,
      requestedAt: pending.requestedAt,
      toolName: pending.toolName
    )
  }

  /// Parks an `agent.ask_user` tool call until the user answers the question in the
  /// conversation. The agent surfaces as WAITING_USER with the question as its attention reason
  /// and the choices rendered as buttons; the returned value is the user's answer (a choice, a
  /// free-typed reply, or "" when the run dies first).
  public func requestChoice(
    agentID: UUID,
    question: String,
    choices: [String],
    multiSelect: Bool = false
  ) async throws -> String {
    guard agents[agentID]?.snapshot.exitCode == nil, agents[agentID] != nil else {
      throw RuntimeError.agentNotFound(agentID)
    }
    let prompt = AgentChoicePrompt(
      requestID: "",
      question: sanitizedAttentionReason(question),
      choices: choices.map { String($0.prefix(200)) }.filter { !$0.isEmpty },
      multiSelect: multiSelect
    )
    return await withCheckedContinuation { continuation in
      var agent = agents[agentID]!
      let wasIdle = pendingChoices[agentID, default: []].isEmpty
      pendingChoices[agentID, default: []].append(
        PendingChoice(prompt: prompt, continuation: continuation))
      if wasIdle {
        agent.snapshot.pendingChoice = prompt
        agent.snapshot.attentionReason = prompt.question
      }
      agent.snapshot.attentionToken = "agent-choice"
      transition(&agent, to: .waitingUser, confidence: 1)
      agents[agentID] = agent
      refreshDelegatingParent(agentID)
    }
  }

  /// Answers the oldest pending agent question. Tool-served questions resume their parked
  /// `agent.ask_user` call; provider-native ones (Hermes clarify) get the answer written to the
  /// process's stdin, where the bridge relays it as `clarify.respond`.
  public func resolveChoice(agentID: UUID, answer: String) throws {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    guard var queue = pendingChoices[agentID], !queue.isEmpty else {
      throw RuntimeError.noPendingPermission(agentID)
    }
    let pending = queue.removeFirst()
    pendingChoices[agentID] = queue.isEmpty ? nil : queue
    let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    appendTranscript(.user, text: trimmed.isEmpty ? "(skipped)" : trimmed, to: &agent)
    if let next = queue.first {
      agent.snapshot.pendingChoice = next.prompt
      agent.snapshot.attentionReason = next.prompt.question
      agent.snapshot.attentionToken = "agent-choice"
      transition(&agent, to: .waitingUser, confidence: 1)
    } else {
      agent.snapshot.pendingChoice = nil
      if agent.snapshot.state == .waitingUser {
        transition(&agent, to: .working, confidence: 1)
      }
    }
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    if let continuation = pending.continuation {
      continuation.resume(returning: trimmed)
    } else if let menu = pending.menu {
      // A TUI menu ignores typed text: the answer is the highlight landing on the chosen row.
      // An answer that matches no row (the user typed their own reply) leaves the menu alone,
      // so they can still resolve it in the terminal rather than having Otto guess a row.
      guard
        let index = menu.options.firstIndex(where: {
          $0.caseInsensitiveCompare(trimmed) == .orderedSame
        })
      else { return }
      agent.activeInteractivePrompt = nil
      agent.promptScanBuffer = ""
      agents[agent.snapshot.id] = agent
      try agent.process.send(text: menu.keystrokes(toSelect: index))
    } else {
      // The one-shot bridge reads stdin line-by-line and routes the reply to the pending
      // provider request; newline-terminated so a multi-word answer stays one line.
      try agent.process.send(text: trimmed.replacingOccurrences(of: "\n", with: " ") + "\n")
    }
  }

  /// Whether the agent has a question awaiting a user answer.
  public func hasPendingChoice(agentID: UUID) -> Bool {
    !(pendingChoices[agentID] ?? []).isEmpty
  }

  /// A dying or replaced process can never receive an answer; parked ask_user calls resolve
  /// with an empty answer so the tool call that carried them returns instead of hanging.
  private func cancelPendingChoices(agentID: UUID) {
    guard let queue = pendingChoices.removeValue(forKey: agentID) else { return }
    for pending in queue {
      pending.continuation?.resume(returning: "")
    }
  }

  /// A dying or replaced process can never receive an approval, so every parked request must
  /// resolve as denied — otherwise the otto-mcp bridge call that carried it hangs to timeout.
  private func denyPendingPermissions(agentID: UUID) {
    guard let queue = pendingPermissions.removeValue(forKey: agentID) else { return }
    for pending in queue {
      pending.timeoutTask?.cancel()
      pending.continuation.resume(returning: false)
    }
  }

  /// Forgets a chat: its transcript, result and the provider session a next turn would resume,
  /// so the next message starts a new conversation. The agent's process must have exited.
  public func clearConversation(agentID: UUID) throws {
    guard var agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    guard agent.snapshot.exitCode != nil else {
      throw RuntimeError.launchFailed("Stop the agent before clearing its chat")
    }
    agent.snapshot.transcript = []
    agent.snapshot.result = nil
    agent.snapshot.structuredResult = nil
    agent.snapshot.providerSessionID = nil
    agent.snapshot.attentionReason = nil
    agent.snapshot.childRuns = []
    agent.hiddenTurnTranscript = []
    agents[agentID] = agent
  }

  public func snapshot(agentID: UUID) throws -> AgentRuntimeSnapshot {
    guard let agent = agents[agentID] else { throw RuntimeError.agentNotFound(agentID) }
    return projectedSnapshot(agent.snapshot)
  }

  public func allSnapshots() -> [AgentRuntimeSnapshot] {
    agents.values.map { projectedSnapshot($0.snapshot) }
  }

  /// Pulls any provider-owned turns that reached disk after the runtime's first DONE event. Team
  /// rooms use this while bridging interactive CLIs whose session projection flushes late.
  public func refreshProviderTranscript(agentID: UUID) {
    guard var agent = agents[agentID] else { return }
    mergeHarvestedSessionTurns(into: &agent)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
  }

  public func activeProcessIDs() -> [UUID] {
    agents.values.compactMap { $0.snapshot.exitCode == nil ? $0.snapshot.id : nil }
  }

  public struct ActiveProcess: Sendable {
    public let snapshot: AgentRuntimeSnapshot
    public let processID: pid_t
  }

  /// Live supervised processes with their OS pids, for shutdown assessment: idle harnesses can
  /// be stopped silently, while working agents and busy shells deserve a confirmation.
  public func activeProcesses() -> [ActiveProcess] {
    agents.values.compactMap { agent in
      guard agent.snapshot.exitCode == nil else { return nil }
      return ActiveProcess(
        snapshot: agent.snapshot, processID: agent.process.processIdentifier)
    }
  }

  public func stopAll(gracePeriod: Duration = .seconds(2)) async {
    let ids = activeProcessIDs()
    for id in ids { try? stop(agentID: id) }
    let deadline = ContinuousClock.now + gracePeriod
    while ContinuousClock.now < deadline {
      if ids.allSatisfy({ agents[$0]?.snapshot.exitCode != nil }) { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
    for id in ids where agents[id]?.snapshot.exitCode == nil {
      try? agents[id]?.process.forceTerminate()
    }
  }

  public func history(agentID: UUID) -> [AgentRunRecord] {
    runHistory[agentID, default: []]
  }

  private func ingest(_ data: Data, for id: UUID, runID: UUID) {
    guard var agent = agents[id], agent.runID == runID else { return }
    let text = String(decoding: data, as: UTF8.self)
    agent.scrollback.append(data)
    agent.snapshot.output = agent.scrollback.text
    agent.snapshot.outputStartOffset = agent.scrollback.startOffset
    agent.snapshot.outputEndOffset = agent.scrollback.endOffset
    agent.pendingText += text
    eventContinuation.yield(.output(agentID: id, text: text))
    eventBus.publish(
      OttoEvent(type: .agentOutputAppended, nodeID: id, byteCount: data.count))

    let normalized = agent.pendingText.replacingOccurrences(of: "\r", with: "")
    var lines = normalized.components(separatedBy: "\n")
    agent.pendingText = lines.removeLast()
    if agent.snapshot.executionMode == .interactiveProvider {
      // Title animations can run indefinitely without a newline while waiting for approval.
      agent.pendingText = String(agent.pendingText.suffix(65_536))
    }
    for line in lines {
      if case .markers = agent.parser {
        consumeMarker(line: line, agent: &agent)
      } else {
        consumeProvider(line: line, agent: &agent)
      }
    }
    consumeInteractivePrompt(from: text, agent: &agent)
    noteTerminalOutput(&agent, id: id)
    agents[id] = agent
    refreshDelegatingParent(id)
    scheduleInteractiveCompletionIfNeeded(agentID: id, rawChunk: text)
  }

  private func consumeMarker(line: String, agent: inout ManagedAgent) {
    if let value = OttoTranscriptMarkers.statusValue(in: line),
      let state = AgentLifecycleState(rawValue: value.trimmingCharacters(in: .whitespaces))
    {
      transition(&agent, to: state, confidence: 1)
    }
    if let value = OttoTranscriptMarkers.resultValue(in: line) {
      let result = value.trimmingCharacters(in: .whitespaces)
      agent.snapshot.result = result
      appendTranscript(.assistant, text: result, to: &agent)
    }
  }

  private static func isTextGuessedWait(_ event: ParsedAgentEvent) -> Bool {
    switch event {
    case .permissionRequested, .waitingForUser: true
    case .state(let state, _): state == .waitingPermission || state == .waitingUser
    default: false
    }
  }

  private func consumeProvider(line: String, agent: inout ManagedAgent) {
    // A native TUI's screen is prose, not protocol: a line that merely mentions "permission" and
    // "approve" (the agent quoting a prompt, say) is not a prompt. Interactive runs take their
    // blocking prompts only from InteractivePromptDetector, which keys on the menu's own
    // Enter/Esc footer, so the parser's text guesses must not raise a card nothing stands behind.
    let screenDriven = agent.snapshot.executionMode == .interactiveProvider
    for event in agent.parser.ingest(line: line) {
      if screenDriven, Self.isTextGuessedWait(event) { continue }
      switch event {
      case .sessionStarted(let sessionID):
        agent.snapshot.providerSessionID = sessionID
      case .state(let state, let confidence):
        // Streaming providers repeat their active state for each message/delta. Output
        // already schedules a coalesced snapshot refresh; these are not lifecycle changes.
        // Keep waiting and terminal events intact because they can carry new requests/results.
        if state == .working || state == .idle,
          agent.snapshot.state == state, agent.snapshot.confidence == confidence
        {
          continue
        }
        transition(&agent, to: state, confidence: confidence)
      case .permissionRequested(let reason):
        agent.snapshot.attentionReason = sanitizedAttentionReason(reason)
        transition(&agent, to: .waitingPermission, confidence: 0.99)
      case .waitingForUser(let reason):
        agent.snapshot.attentionReason = sanitizedAttentionReason(reason)
        transition(&agent, to: .waitingUser, confidence: 0.99)
      case .choiceRequested(let prompt):
        // Provider-native question (Hermes clarify): the process's own bridge answers it from
        // stdin, so no continuation parks here — resolveChoice writes the reply line.
        pendingChoices[agent.snapshot.id, default: []].append(
          PendingChoice(prompt: prompt, continuation: nil))
        if agent.snapshot.pendingChoice == nil {
          agent.snapshot.pendingChoice = prompt
          agent.snapshot.attentionReason = sanitizedAttentionReason(prompt.question)
        }
        agent.snapshot.attentionToken = "agent-choice"
        transition(&agent, to: .waitingUser, confidence: 0.99)
      case .result(let result):
        agent.snapshot.structuredResult = result
        agent.snapshot.result = result.summaryCandidate
        // Messages were already projected as they completed; the summary only lands as a new
        // entry when the provider's final result differs from the last message (dedupe below).
        appendTranscript(.assistant, text: result.summaryCandidate, to: &agent)
        attachTurnStats(result, to: &agent)
      case .assistantMessage(let text):
        appendTranscript(.assistant, text: text, to: &agent)
      case .reasoning(let text):
        appendTranscript(.assistant, kind: .reasoning, text: text, to: &agent)
      case .toolInvoked(let name, let detail):
        appendTranscript(
          .activity, kind: .toolCall, text: detail.isEmpty ? name : detail, detail: name,
          to: &agent)
      case .childStarted(let child):
        if let index = agent.snapshot.childRuns.firstIndex(where: { $0.id == child.id }) {
          agent.snapshot.childRuns[index] = child
        } else {
          agent.snapshot.childRuns.append(child)
        }
      case .childUpdated(let id, let activity, let toolIncrement):
        guard let index = agent.snapshot.childRuns.firstIndex(where: { $0.id == id }) else {
          break
        }
        agent.snapshot.childRuns[index].activity = activity
        agent.snapshot.childRuns[index].toolCount += toolIncrement
      case .childCompleted(let id, let failed, let inputTokens, let outputTokens):
        guard let index = agent.snapshot.childRuns.firstIndex(where: { $0.id == id }) else {
          break
        }
        agent.snapshot.childRuns[index].state = failed ? .failed : .done
        agent.snapshot.childRuns[index].completedAt = .now
        agent.snapshot.childRuns[index].inputTokens = inputTokens
        agent.snapshot.childRuns[index].outputTokens = outputTokens
      case .diagnostic(let message):
        appendTranscript(.activity, kind: .notice, text: message, to: &agent)
      }
    }
  }

  private func consumeInteractivePrompt(from text: String, agent: inout ManagedAgent) {
    guard agent.snapshot.executionMode == .interactiveProvider else { return }
    let plainText = agent.promptTextFilter.ingest(text)
    guard !plainText.isEmpty else { return }
    agent.promptScanBuffer = String((agent.promptScanBuffer + plainText).suffix(4_096))
    if agent.trustFooterPending,
      let footer = Self.navigationFooterRange(in: agent.promptScanBuffer)
    {
      // Drop the tail of the already-answered trust screen, footer line included.
      agent.trustFooterPending = false
      agent.promptScanBuffer = String(agent.promptScanBuffer[footer.upperBound...])
    }
    guard
      let prompt = InteractivePromptDetector.detect(
        in: agent.promptScanBuffer,
        provider: agent.snapshot.provider
      )
    else {
      // The trigger text has scrolled out of the rolling window without the user answering
      // through Otto — they resolved it directly in the terminal (for example completing a
      // sign-in). Release the waiting state so chat prompts flow normally again.
      if agent.activeInteractivePrompt != nil,
        [.waitingUser, .waitingPermission].contains(agent.snapshot.state)
      {
        agent.activeInteractivePrompt = nil
        agent.snapshot.attentionReason = nil
        agent.snapshot.attentionToken = nil
        pendingChoices[agent.snapshot.id]?.removeAll { $0.menu != nil }
        agent.snapshot.pendingChoice = pendingChoices[agent.snapshot.id]?.first?.prompt
        transition(&agent, to: .working, confidence: 0.7)
      }
      return
    }
    if prompt.token == agent.activeInteractivePrompt, let menu = prompt.menu,
      let index = pendingChoices[agent.snapshot.id]?.firstIndex(where: { $0.menu != nil }),
      var pending = pendingChoices[agent.snapshot.id]?[index]
    {
      pending.menu = menu
      // A menu can arrive across several PTY reads. If the question was raised before every row
      // had painted, offer the rows that arrived since rather than a truncated choice.
      if menu.options.count > pending.prompt.choices.count {
        let wasShown = agent.snapshot.pendingChoice == pending.prompt
        pending.prompt.choices = menu.options
        if wasShown { agent.snapshot.pendingChoice = pending.prompt }
      }
      pendingChoices[agent.snapshot.id]?[index] = pending
    }
    guard
      prompt.token != agent.activeInteractivePrompt
        || (agent.snapshot.pendingChoice == nil && prompt.menu != nil)
    else { return }
    agent.activeInteractivePrompt = prompt.token

    if let response = prompt.automaticResponse,
      ["claude-workspace-trust", "kimi-workspace-trust"].contains(prompt.token),
      !agent.confirmedWorkspaceTrust
    {
      agent.confirmedWorkspaceTrust = true
      // A PTY read can end before the screen's "Enter to confirm · Esc to cancel" line.
      agent.trustFooterPending = Self.navigationFooterRange(in: agent.promptScanBuffer) == nil
      agent.promptScanBuffer = ""
      agent.activeInteractivePrompt = nil
      agent.snapshot.attentionReason = nil
      agent.snapshot.attentionToken = nil
      try? agent.process.send(text: response)
      transition(&agent, to: .idle, confidence: 1)
      return
    }

    agent.snapshot.attentionReason = prompt.reason
    agent.snapshot.attentionToken = prompt.token

    // A menu Otto could read becomes a real question in chat, so the user answers with a button
    // instead of hunting for the highlight in a TUI that is repainting under them.
    if let menu = prompt.menu, menu.options.count >= 2,
      pendingChoices[agent.snapshot.id, default: []].isEmpty
    {
      let choice = AgentChoicePrompt(
        requestID: prompt.token,
        question: prompt.reason,
        choices: menu.options
      )
      pendingChoices[agent.snapshot.id, default: []].append(
        PendingChoice(prompt: choice, continuation: nil, menu: menu))
      agent.snapshot.pendingChoice = choice
    }

    transition(&agent, to: prompt.state, confidence: 0.95)
  }

  /// Shortens the quiet period before a command terminal is read as waiting. Tests only.
  public func setTerminalInputQuietInterval(_ interval: Duration) {
    terminalInputQuietInterval = interval
  }

  /// Command terminals (`terminal.run`) are watched for a prompt the person has to answer: new
  /// output ends any wait, and output that then stays quiet on a prompt-like line starts one.
  /// Bare shells from `terminal.open` sit at a prompt by design and are never flagged.
  private func noteTerminalOutput(_ agent: inout ManagedAgent, id: UUID) {
    guard agent.snapshot.executionMode == .terminal, agent.successfulExitState == .done else {
      return
    }
    if agent.snapshot.state == .waitingUser,
      TerminalInputWaitDetector.isTerminalAttentionToken(agent.snapshot.attentionToken)
    {
      transition(&agent, to: .working, confidence: 1)
    }
    let runID = agent.runID
    let expectedEndOffset = agent.snapshot.outputEndOffset
    let interval = terminalInputQuietInterval
    terminalQuietTasks[id]?.cancel()
    terminalQuietTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: interval)
      guard !Task.isCancelled else { return }
      await self?.evaluateTerminalQuiet(
        id: id, runID: runID, expectedEndOffset: expectedEndOffset)
    }
  }

  private func evaluateTerminalQuiet(id: UUID, runID: UUID, expectedEndOffset: Int) {
    guard var agent = agents[id], agent.runID == runID,
      agent.snapshot.outputEndOffset == expectedEndOffset
    else { return }
    terminalQuietTasks[id] = nil
    guard agent.snapshot.exitCode == nil, agent.snapshot.state == .working else { return }
    let echoDisabled = !agent.process.echoesInput
    guard
      let prompt = TerminalInputWaitDetector.waitingPrompt(
        in: agent.snapshot.output, echoDisabled: echoDisabled)
    else { return }
    // Only the prompt the program printed is kept. Keystrokes never reach the snapshot: they go
    // straight to the PTY, and with echo off the program does not print them back either.
    agent.snapshot.attentionReason = sanitizedAttentionReason(prompt)
    agent.snapshot.attentionToken =
      echoDisabled
      ? TerminalInputWaitDetector.hiddenInputToken : TerminalInputWaitDetector.inputToken
    transition(&agent, to: .waitingUser, confidence: 0.8)
    agents[id] = agent
    refreshDelegatingParent(id)
  }

  /// The range from the start of `text` through the end of the first line carrying a TUI menu's
  /// navigation footer ("Enter to confirm · Esc to cancel"), if one is present.
  private static func navigationFooterRange(in text: String) -> Range<String.Index>? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let lowered = line.lowercased()
      guard lowered.contains("enter to confirm") || lowered.contains("esc to cancel") else {
        continue
      }
      let end = line.endIndex < text.endIndex ? text.index(after: line.endIndex) : line.endIndex
      return text.startIndex..<end
    }
    return nil
  }

  private func scheduleInteractiveCompletionIfNeeded(agentID: UUID, rawChunk: String) {
    guard let agent = agents[agentID],
      agent.snapshot.executionMode == .interactiveProvider,
      agent.snapshot.state == .working,
      agent.activeInteractivePrompt == nil,
      agent.snapshot.pendingChoice == nil,
      InteractiveCompletionDetector.isReadyForNextPrompt(
        recentText: agent.promptScanBuffer,
        rawChunk: rawChunk,
        provider: agent.snapshot.provider
      )
    else { return }
    let expectedEndOffset = agent.snapshot.outputEndOffset
    interactiveCompletionTasks[agentID]?.cancel()
    interactiveCompletionTasks[agentID] = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1_500))
      guard !Task.isCancelled else { return }
      await self?.completeInteractiveAgentIfQuiet(
        agentID: agentID,
        expectedEndOffset: expectedEndOffset
      )
    }
  }

  private func completeInteractiveAgentIfQuiet(agentID: UUID, expectedEndOffset: Int) {
    guard var agent = agents[agentID],
      agent.snapshot.executionMode == .interactiveProvider,
      agent.snapshot.state == .working,
      agent.activeInteractivePrompt == nil,
      agent.snapshot.pendingChoice == nil,
      agent.snapshot.outputEndOffset == expectedEndOffset
    else { return }
    let excerpt = InteractiveCompletionDetector.completionExcerpt(from: agent.snapshot.output)
    agent.snapshot.result = excerpt.isEmpty ? "Completed the requested task" : excerpt
    // The excerpt is scraped from a painted TUI screen. It informs the status footer and voice
    // summaries, but it is not conversational prose — it must never appear as an assistant chat
    // message. The conversation the TUI actually held comes from the provider's own session
    // records instead, so the chat surface stays in sync with terminal-driven turns.
    mergeHarvestedSessionTurns(into: &agent)
    transition(&agent, to: .done, confidence: 0.82)
    agents[agentID] = agent
    refreshDelegatingParent(agentID)
    interactiveCompletionTasks[agentID] = nil
  }

  /// Pulls turns the user drove through the provider's interactive TUI from the provider's
  /// exact on-disk session file into the transcript. A provider event or an explicit resume
  /// must establish its identity first; workspace and modification time cannot establish ownership.
  private func mergeHarvestedSessionTurns(into agent: inout ManagedAgent) {
    guard agent.snapshot.executionMode == .interactiveProvider,
      [.claudeCode, .codex].contains(agent.snapshot.provider)
    else { return }
    let harvest = ProviderSessionStore.harvest(
      provider: agent.snapshot.provider,
      workingDirectory: agent.workingDirectory,
      since: agent.snapshot.startedAt,
      sessionID: agent.snapshot.providerSessionID,
      providerHome: launchProviderHomes[agent.snapshot.id]
    )
    if let sessionID = harvest.sessionID, !sessionID.isEmpty {
      agent.snapshot.providerSessionID = sessionID
    }
    guard harvest.turns.count > agent.harvestedTurnCount else { return }
    for turn in harvest.turns.dropFirst(agent.harvestedTurnCount) {
      appendTranscript(turn.role, text: turn.text, to: &agent)
    }
    agent.harvestedTurnCount = harvest.turns.count
  }

  private func sanitizedAttentionReason(_ reason: String, limit: Int = 240) -> String {
    let plain = TerminalOutputSearch.plainText(reason)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(plain.prefix(limit))
  }

  /// Puts the turn's time and tokens on its last reply. The turn runs from the person's message
  /// to this result; the provider's own duration is used when it reports one.
  private func attachTurnStats(_ result: AgentResult, to agent: inout ManagedAgent) {
    guard !agent.hiddenTurnActive,
      let replyIndex = agent.snapshot.transcript.lastIndex(where: {
        $0.role == .assistant && $0.kind == .text
      })
    else { return }
    let transcript = agent.snapshot.transcript
    // A turn that added no reply must not stamp its stats on the previous turn's reply.
    guard !transcript[(replyIndex + 1)...].contains(where: { $0.role == .user }) else { return }
    let turnStart =
      transcript[..<replyIndex].last(where: { $0.role == .user })?.createdAt
      ?? agent.snapshot.startedAt
    let measured = max(0, Date.now.timeIntervalSince(turnStart))
    let reported = result.durationMilliseconds.map { Double($0) / 1_000 }
    agent.snapshot.transcript[replyIndex].turnStats = AgentTurnStats(
      durationSeconds: reported ?? measured,
      inputTokens: result.inputTokens, outputTokens: result.outputTokens)
  }

  private func appendTranscript(
    _ role: AgentTranscriptRole,
    kind: AgentTranscriptKind = .text,
    text: String,
    detail: String? = nil,
    to agent: inout ManagedAgent
  ) {
    if role == .user, PromptSubmission.isHiddenControlPrompt(text) { return }
    let projected: String?
    if role == .user {
      projected = PromptSubmission.verbatimText(from: PromptSubmission.originalUserText(text))
    } else {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      projected = trimmed.isEmpty ? nil : trimmed
    }
    guard let projected else { return }
    let text =
      role == .assistant && kind == .text
      ? ChatImageStore.preservingImages(
        in: projected, workingDirectory: agent.workingDirectory,
        storageRoot: controlPlane?.workspacePath)
      : projected
    if role == .assistant, kind == .text,
      agent.snapshot.result?.trimmingCharacters(in: .whitespacesAndNewlines) == projected
    {
      agent.snapshot.result = text
    }
    if agent.hiddenTurnActive {
      // Only the final conversational prose is needed by the team-room coordinator. Reasoning,
      // tool activity, and provider diagnostics stay out of both user-visible transcripts.
      guard role == .assistant, kind == .text else { return }
      if let last = agent.hiddenTurnTranscript.last,
        last.role == role,
        last.kind == kind,
        last.text == text
      {
        return
      }
      agent.hiddenTurnTranscript.append(
        AgentTranscriptEntry(role: role, kind: kind, text: text, detail: detail))
      return
    }
    if let last = agent.snapshot.transcript.last,
      last.role == role,
      last.kind == kind,
      last.text == text
    {
      return
    }
    agent.snapshot.transcript.append(
      AgentTranscriptEntry(role: role, kind: kind, text: text, detail: detail))
    // Conversation is a reading surface, not the unbounded diagnostic log. Keep enough turns for
    // a long working session while preventing persistent agent nodes from growing without limit.
    agent.snapshot.transcript = Array(agent.snapshot.transcript.suffix(200))
  }

  /// The request a run is parked on inside the supervisor: the oldest tool-permission request,
  /// otherwise the oldest tool-served question. Both hold a continuation, so the provider stays
  /// blocked until the user answers here; the conversation must keep showing the card for them.
  private func parkedAttention(agentID: UUID) -> (
    state: AgentLifecycleState, reason: String, token: String?, choice: AgentChoicePrompt?
  )? {
    if let permission = pendingPermissions[agentID]?.first {
      return (.waitingPermission, permission.reason, nil, nil)
    }
    if let choice = pendingChoices[agentID]?.first, choice.continuation != nil {
      return (.waitingUser, choice.prompt.question, "agent-choice", choice.prompt)
    }
    return nil
  }

  private func transition(
    _ agent: inout ManagedAgent,
    to requestedState: AgentLifecycleState,
    confidence requestedConfidence: Double
  ) {
    var state = requestedState
    var confidence = requestedConfidence
    if state != .waitingPermission, state != .waitingUser {
      agent.snapshot.attentionReason = nil
      agent.snapshot.attentionToken = nil
      if agent.snapshot.pendingChoice != nil {
        // The provider moved on without an answer (Hermes clarify times out server-side and
        // continues), so drop stdin-answered questions. Tool-served questions keep their parked
        // continuation: their run stays blocked inside the tool call until answered or killed.
        agent.snapshot.pendingChoice = nil
        let id = agent.snapshot.id
        if let queue = pendingChoices[id] {
          let remaining = queue.filter { $0.continuation != nil }
          pendingChoices[id] = remaining.isEmpty ? nil : remaining
        }
      }
    }
    // A run parked on an approval or question cannot be working or idle: the provider is blocked
    // inside the tool call until the user answers. Its stream still prints records meanwhile
    // (further content blocks of the same assistant message, system records, results of tools
    // that were already running), and each one reports WORKING. Letting that through hid the
    // card a moment after it appeared while the request stayed parked, stranding the agent.
    if state == .working || state == .idle,
      let parked = parkedAttention(agentID: agent.snapshot.id)
    {
      agent.snapshot.attentionReason = parked.reason
      agent.snapshot.attentionToken = parked.token
      if let choice = parked.choice { agent.snapshot.pendingChoice = choice }
      // Already showing it: a provider heartbeat is not a lifecycle change worth publishing.
      if agent.snapshot.state == parked.state { return }
      state = parked.state
      confidence = 1
    }
    agent.snapshot.state = state
    agent.snapshot.confidence = confidence
    if state == .done || state == .failed || state == .interrupted || state == .stopped {
      agent.snapshot.completedAt = .now
      // A parent exiting is not evidence that each child succeeded.
      for index in agent.snapshot.childRuns.indices
      where agent.snapshot.childRuns[index].state.isActive {
        agent.snapshot.childRuns[index].state =
          (state == .stopped || state == .interrupted) ? .stopped : .unknown
        agent.snapshot.childRuns[index].completedAt = .now
      }
    }
    eventContinuation.yield(
      .stateChanged(agentID: agent.snapshot.id, state: state, confidence: confidence))
    eventBus.publish(
      OttoEvent(
        type: .agentStatusChanged,
        nodeID: agent.snapshot.id,
        state: state,
        confidence: confidence,
        runID: agent.snapshot.runID
      ))
    if state == .done, let result = agent.snapshot.result {
      eventContinuation.yield(
        .completed(agentID: agent.snapshot.id, result: result, confidence: confidence))
      eventBus.publish(
        OttoEvent(
          type: .agentRunCompleted,
          nodeID: agent.snapshot.id,
          state: state,
          confidence: confidence,
          runID: agent.snapshot.runID
        ))
    } else if state == .failed {
      eventBus.publish(
        OttoEvent(
          type: .agentRunFailed,
          nodeID: agent.snapshot.id,
          state: state,
          confidence: confidence,
          runID: agent.snapshot.runID
        ))
    }
  }

  private func processExited(id: UUID, runID: UUID, code: Int32) {
    interactiveCompletionTasks[id]?.cancel()
    interactiveCompletionTasks[id] = nil
    guard var agent = agents[id], agent.runID == runID else { return }
    terminalQuietTasks[id]?.cancel()
    terminalQuietTasks[id] = nil
    agent.pendingExitCode = code
    if agent.outputEnded { finalizeExit(&agent, id: id, code: code) }
    agents[id] = agent
    refreshDelegatingParent(id)
  }

  private func outputEnded(id: UUID, runID: UUID) {
    guard var agent = agents[id], agent.runID == runID else { return }
    agent.outputEnded = true
    // Providers that mark a finished turn by closing the stream rather than by a terminating
    // record report their result here; the rest return nothing because they already have.
    for event in agent.parser.finish() {
      switch event {
      case .state(let state, let confidence):
        transition(&agent, to: state, confidence: confidence)
      case .result(let result):
        agent.snapshot.structuredResult = result
        agent.snapshot.result = result.summaryCandidate
        appendTranscript(.assistant, text: result.summaryCandidate, to: &agent)
        attachTurnStats(result, to: &agent)
      case .diagnostic(let message):
        appendTranscript(.activity, kind: .notice, text: message, to: &agent)
      case .childStarted(let child):
        agent.snapshot.childRuns.append(child)
      case .childUpdated(let id, let activity, let toolIncrement):
        if let index = agent.snapshot.childRuns.firstIndex(where: { $0.id == id }) {
          agent.snapshot.childRuns[index].activity = activity
          agent.snapshot.childRuns[index].toolCount += toolIncrement
        }
      case .childCompleted(let id, let failed, let inputTokens, let outputTokens):
        if let index = agent.snapshot.childRuns.firstIndex(where: { $0.id == id }) {
          agent.snapshot.childRuns[index].state = failed ? .failed : .done
          agent.snapshot.childRuns[index].completedAt = .now
          agent.snapshot.childRuns[index].inputTokens = inputTokens
          agent.snapshot.childRuns[index].outputTokens = outputTokens
        }
      default:
        break
      }
    }
    if let code = agent.pendingExitCode { finalizeExit(&agent, id: id, code: code) }
    agents[id] = agent
    refreshDelegatingParent(id)
  }

  private func finalizeExit(_ agent: inout ManagedAgent, id: UUID, code: Int32) {
    denyPendingPermissions(agentID: id)
    cancelPendingChoices(agentID: id)
    // Final chance to capture turns the TUI wrote to disk on shutdown (some only flush then).
    mergeHarvestedSessionTurns(into: &agent)
    agent.snapshot.exitCode = code
    agent.snapshot.processID = nil
    if ![.done, .failed, .interrupted, .stopped].contains(agent.snapshot.state) {
      transition(
        &agent,
        to: code == 0 ? agent.successfulExitState : .failed,
        confidence: 1
      )
    }
    eventContinuation.yield(.exited(agentID: id, code: code))
    eventBus.publish(OttoEvent(type: .agentExited, nodeID: id, exitCode: code))
    archive(agent)
    if agent.scheduledWorker {
      Task { await resourceScheduler.release(id) }
    }
  }

  private func archive(_ agent: ManagedAgent) {
    guard let completedAt = agent.snapshot.completedAt else { return }
    let record = AgentRunRecord(
      id: agent.runID,
      nodeID: agent.snapshot.id,
      provider: agent.snapshot.provider,
      state: agent.snapshot.state,
      exitCode: agent.snapshot.exitCode,
      startedAt: agent.snapshot.startedAt,
      completedAt: completedAt,
      output: String(agent.snapshot.output.suffix(historyOutputCapacity)),
      outputStartOffset: max(
        agent.snapshot.outputStartOffset,
        agent.snapshot.outputEndOffset - historyOutputCapacity
      ),
      outputEndOffset: agent.snapshot.outputEndOffset
    )
    var records = runHistory[agent.snapshot.id, default: []]
    if let index = records.firstIndex(where: { $0.id == record.id }) {
      records[index] = record
    } else {
      records.append(record)
    }
    runHistory[agent.snapshot.id] = Array(records.suffix(historyLimit))
  }
}
