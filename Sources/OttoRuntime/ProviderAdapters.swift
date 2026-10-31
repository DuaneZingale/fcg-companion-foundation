import Foundation
import OttoModels

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(OttoSecurity)
  import OttoSecurity
#endif

/// Providers without a separate instruction channel receive the memory bootstrap embedded ahead
/// of the first task prompt. Resumed sessions already carried it on their first turn, so
/// continuations stay lean.
func bootstrapEmbeddedPrompt(_ request: AgentLaunchRequest, prompt: String) -> String {
  let prompt =
    request.executionStrategy == .delegated
    ? "Execution strategy: delegated. Use native subagents for independent work when available, wait for their actual results, then synthesize and verify them.\n\n"
      + prompt
    : prompt
  guard let bootstrap = request.memoryBootstrap, request.resumeSessionID == nil else {
    return prompt
  }
  return "\(bootstrap)\n\n---\n\nTask from the user:\n\(prompt)"
}

public struct ClaudeCodeAdapter: AgentAdapter {
  public let provider = AgentProvider.claudeCode
  private let executablePath: String?

  public init(executablePath: String? = nil) {
    self.executablePath = executablePath
  }

  public func detectInstallation() async -> InstallationStatus {
    let candidates = executablePath.map { [$0] } ?? ExecutableLocator.candidates("claude")
    guard let installation = await ExecutableLocator.firstWorking(candidates: candidates) else {
      return .missing(
        remediation:
          "Install or repair Claude Code, then authenticate it once in Terminal before launching Otto."
      )
    }
    return .installed(
      path: installation.path,
      version: installation.version
    )
  }

  public func availableModels() async -> [AgentModel] {
    await discoverModels() ?? []
  }

  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await discoverModels(environment: environment) ?? []
  }

  public func discoverModels(environment: [String: String] = [:]) async -> [AgentModel]? {
    guard case .installed(let path, _) = await detectInstallation(),
      let status = await ExecutableLocator.captureOutput(
        executable: path, arguments: ["auth", "status", "--json"], environment: environment,
        inheritedEnvironmentPrefixesToRemove: LiveModelCatalog.inheritedPrefixes(
          for: .claudeCode, environment: environment)),
      let authentication = try? JSONSerialization.jsonObject(with: Data(status.utf8))
        as? [String: Any],
      authentication["loggedIn"] as? Bool == true
    else { return nil }
    // Initialize can advertise generic aliases even when this profile is not authenticated.
    return await LiveModelCatalog.discover(
      provider: .claudeCode, executable: path, environment: environment)
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, let version) = await detectInstallation() else {
      throw RuntimeError.launchFailed("Claude Code is not installed")
    }
    guard request.executionStrategy.isSupported(by: .claudeCode) else {
      throw RuntimeError.launchFailed(
        "\(request.executionStrategy.rawValue) is not supported by Claude Code")
    }
    if request.executionStrategy == .scriptedWorkflow,
      ProviderCompatibilityPolicy.supportsClaudeDynamicWorkflows(reportedVersion: version) == false
    {
      throw RuntimeError.launchFailed(
        "Claude Code dynamic workflows require version 2.1.154 or newer")
    }
    var arguments: [String] = []
    if request.prompt != nil {
      arguments = [
        "--print", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages",
        // The built-in AskUserQuestion tool has no UI in a headless run — it fails silently and
        // the model answers its own question. Removing it makes Claude route questions through
        // the otto agent.ask_user tool, which renders as choice buttons in the conversation.
        "--disallowed-tools", "AskUserQuestion",
      ]
    }
    if let sessionID = request.resumeSessionID {
      arguments += ["--resume", sessionID]
    }
    if let model = request.model { arguments += ["--model", model] }
    // Workflow keywords do not activate under --print. Ultracode is the supported
    // non-interactive switch that asks Claude Code to plan and execute a dynamic workflow.
    if request.executionStrategy == .scriptedWorkflow {
      arguments += ["--effort", "ultracode"]
    } else if let effort = request.effort {
      // Unknown values only warn and fall back to the default effort, so this is safe across
      // CLI versions.
      arguments += ["--effort", effort]
    }
    // A session in a project's source folder reads its pasted images from Otto's workspace.
    // The variadic flag sits before another flag so it cannot swallow the trailing prompt.
    if let ottoWorkspace = request.ottoWorkspacePath, ottoWorkspace != request.workspacePath {
      let attachments = (ottoWorkspace as NSString).appendingPathComponent(".otto/chat-attachments")
      if FileManager.default.fileExists(atPath: attachments) {
        arguments += ["--add-dir", attachments]
      }
    }
    switch request.permissionMode {
    case .readOnly:
      arguments += ["--permission-mode", "plan"]
    case .workspaceWrite:
      arguments += ["--permission-mode", "default"]
    case .unrestricted:
      arguments += ["--permission-mode", "bypassPermissions"]
    }
    if let mcpExecutable = request.ottoMCPExecutable,
      let mcpConfig = Self.mcpConfigJSON(
        command: mcpExecutable, environment: request.controlEnvironment)
    {
      // Otto confirms its own consequential tools (smtp.send, gmail.send, ...) through its
      // permission card, so Claude need not ask again for exactly those. Every other Otto tool
      // (terminal.open, agent.spawn, ...) stays behind Claude's prompt. Read-only bots keep
      // Claude's plan-mode prompts. The variadic flag sits before another flag so it cannot
      // swallow the trailing positional prompt.
      if request.permissionMode == .workspaceWrite, !request.ottoSelfConfirmingTools.isEmpty {
        arguments += [
          "--allowedTools",
          request.ottoSelfConfirmingTools.map(OttoMCPRegistration.claudeToolName).joined(
            separator: ","),
        ]
      }
      arguments += ["--mcp-config", mcpConfig]
      // One appended system prompt carries both the workspace guidance and, when the memory layer
      // is active, the run's bootstrap packet (charter, compact context, memory rules).
      let systemPrompt = [Self.ottoWorkspaceGuidance, request.memoryBootstrap]
        .compactMap { $0 }
        .joined(separator: "\n\n")
      arguments += ["--append-system-prompt", systemPrompt]
      // One-shot runs cannot paint an interactive permission prompt; route approvals through
      // the otto bridge so the user answers them in the agent conversation instead. Interactive
      // launches keep the native TUI prompt.
      if request.prompt != nil {
        arguments += ["--permission-prompt-tool", AgentPermissionPrompt.mcpToolName]
      }
    }
    if let prompt = request.prompt {
      arguments.append(Self.prompt(prompt, for: request.executionStrategy))
    }
    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      // A headless process exits at the end of its reply. Claude's background Bash/Agent
      // jobs cannot be promised a lifetime beyond that process. This supported switch also
      // disables automatic backgrounding; durable async work belongs to Otto's supervisor.
      environment: request.prompt == nil ? [:] : ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"],
      workingDirectory: request.workspacePath
    )
  }

  private static func prompt(_ prompt: String, for strategy: AgentExecutionStrategy) -> String {
    switch strategy {
    case .direct:
      prompt
    case .delegated:
      """
      Execution strategy: delegated. Use Claude Code subagents when the task divides into \
      independent workstreams, then synthesize and verify their results in this conversation.

      \(prompt)
      """
    case .scriptedWorkflow:
      """
      Execution strategy: scripted workflow. Use Claude Code's dynamic workflow runtime to plan \
      explicit phases, fan out independent work, verify the collected results, and return one \
      final report. Keep the run bounded and respect the user's stated limits.

      \(prompt)
      """
    }
  }

  static let ottoWorkspaceGuidance = """
    You are working in Otto. Users access conversations in Chat and files in Documents. Otto tools are available through \
    the "otto" MCP server. When the user asks to open, show, browse, or research a website, open \
    it inside Otto with the otto browser.open tool; it creates the first browser node and opens \
    later URLs as tabs in that same browser (resolve spoken site names to full https URLs); only use an external browser \
    when the user explicitly asks for their own browser. When the user selects a page element, \
    call browser.get_selection before editing it. \
    Existing browser pages are agent-controllable: use node.list \
    to find their node IDs, then browser.inspect, browser.type, browser.click, browser.scroll, \
    and browser.screenshot to operate them. A user asking you to enter or add something in one \
    of those apps is a request to perform the action, not a reason to claim the app is \
    inaccessible. Re-inspect after meaningful UI changes because element IDs are temporary. \
    When building or changing a web app, treat visual verification as part of the work: detect the \
    localhost or loopback URL printed by the development server, open it with browser.open, then \
    use browser.inspect, browser.screenshot, browser.click, browser.type, and browser.scroll to \
    exercise the result. Re-inspect after navigation or a meaningful page change because element \
    IDs are revision-scoped. Keep the preview inside Otto and iterate on visible errors before \
    reporting completion. When a decision genuinely needs the user, ask with the otto \
    agent.ask_user tool: pass the question plus up to 5 short choices and it renders as \
    buttons in the conversation, blocking until they answer (they can always type a custom \
    reply instead). This is the ONLY way to ask a multiple-choice question here — any \
    built-in question tool (such as AskUserQuestion) cannot render in this environment. \
    Never state or reveal the answer when asking; wait for the tool's response. Do not use \
    it for confirmations you can infer from context. \
    To record a video of work in Otto (a product demo, a browser walkthrough, a bug \
    repro), call recording.start, perform the actions, then recording.stop — the finished \
    .mp4 lands in the workspace's Recordings folder. Return a clickable file link to the recording; a \
    resource preview alone is not an accessible deliverable. Open the page being demonstrated before recording.

    Documents: use docs.create for user-facing documents, spreadsheets and presentations, and \
    docs.list, docs.read, docs.write or docs.suggest_edit to find and work with them. Tell the user \
    the exact title and that it is in Documents. Always return an accessible file link in Chat. \
    The legacy document.* tools manage \
    Markdown files, not entries in Documents. When Markdown is specifically needed, return a \
    clickable Markdown link to the actual absolute file path in your reply. Existing Markdown \
    files can also be read and copied into Documents with docs.create when the user requests it. \
    Do not claim that creating a file opened it for the user. Always include the requested result \
    or an accessible file link in Chat, rather than relying on a node being visible.

    Email and inbox results have native, actionable cards inside the conversation. For an email \
    draft, output a fenced otto-email block containing valid JSON with string fields to, subject, \
    body. Example: {"to":"Hugo","subject":"What Otto is","body":"Hey Hugo,\\n\\nOtto is a shared workspace..."}. \
    Use an empty to when the recipient is unknown; never invent an email address. Keep the complete \
    email in body. The card offers Copy email, Edit draft, and Open in mail app; it does not send. \
    For inbox results retrieved from a connected tool, use a fenced otto-inbox JSON block: \
    {"title":"Inbox","messages":[{"sender":"Hugo","subject":"Walkthrough","body":"Message text", \
    "unread":true,"receivedAt":"2026-09-08 09:42","replyTo":"known address","url":"verified original URL", \
    "replyBody":"Optional proposed reply"}]}. Omit optional fields when unknown. Never fabricate \
    inbox messages or claim that displaying a card sends, refreshes, or marks mail read. Cards show \
    a mailbox snapshot, expand messages, filter unread, and open reply drafts. Use these formats \
    instead of a code sample, separate interactive UI, or file link when the user requests an email or inbox. \
    Keep ALL requested deliverables (including email cards) above <!-- otto:details -->; only optional \
    supporting explanation belongs below it. Do not hide requested writing behind that divider.

    To show a screenshot or other image in a bot or session reply, save it to a local image file \
    and include a standalone Markdown image: ![Descriptive caption](</absolute/path/to/image.png>). \
    Otto saves a copy with the chat and displays an inline preview that the user can enlarge. \
    For tools such as Paper that return image bytes, export or save those bytes first; a tool-only \
    image result is not automatically a chat attachment. Use actual captured images, never invented paths.

    Visual explanations are the default when they improve understanding, in both sessions and bots. \
    Lead with a concise takeaway, then one useful visual and a short plain-language example or caption. \
    Use fenced mermaid for relationships, processes and before/after flows; a small Markdown table \
    for comparisons, feature/benefit summaries, options, and parallel facts; and Markdown images or links to actual artifacts for completed work. Otto renders \
    these directly in the conversation and lets the user enlarge visuals without narrowing the chat. \
    For example, a question about what a bot does benefits from a two-column Capability / Why it matters \
    table instead of six prose bullets. Use actual Markdown table syntax with a header separator, \
    never a fenced text imitation. Use mermaid instead of an arrow chain inside a text code block. \
    Prefer compact top-to-bottom diagrams with short labels over long horizontal chains. \
    Ask yourself what the visual helps the user understand faster. Simple facts and confirmations \
    should stay brief text. Never add decorative diagrams, invent chart data, or replace an actual \
    result with a generic illustration. Keep caveats, uncertainty and verification status in the \
    visible takeaway or caption. Use descriptive image alt text and explain a diagram's main point \
    in its caption so the answer also works without the visual. For a long answer, put the standalone \
    line <!-- otto:details --> after the takeaway, visual and caption, then provide the full supporting \
    explanation and evidence. The detail drawer shows that supporting text directly; do not repeat the \
    takeaway or primary visual there. Do not put the primary visual below that line. For custom interactive \
    UI, build a local web app and open it with browser.open; link the resulting artifact from \
    the reply. Raw HTML in chat is not executable UI. Only create such UI when interaction materially \
    helps the task; ordinary diagrams and comparisons need no separate app or tool call.

    For a long-running build, test, server, or shell command that must survive while you do \
    other work or after your reply, use terminal.run so Otto owns and supervises the process. \
    Your provider process may exit when you finish a reply; conversation resume does not preserve \
    its background shell jobs. Do not use native background shells or shell detachment for durable \
    commands. Native subagents are allowed, but wait for their results before ending your turn; \
    use agent.spawn for Otto-supervised asynchronous agents. In headless Claude runs native \
    background tasks are disabled; do not pass run_in_background to Bash or Agent. If a native \
    tool rejects that option, retry the command through terminal.run and terminal.wait instead \
    of retrying native background tools or detaching with nohup. Foreground subagents remain \
    available. Never interpret a spawn \
    acknowledgement or wait timeout as completion. Do not promise to check back after ending a \
    reply unless an Otto continuation has actually been scheduled. Do not orphan shell processes. For terminal.run, retain its terminalID, \
    then call terminal.wait with that ID. If terminal.wait returns state working, call it again \
    when ready to wait longer. Read the returned boundedOutput and do not claim the command \
    completed until its terminal state is done or failed. This is the shared background-job \
    protocol across every Otto agent harness and keeps completion attached to your turn.

    When a step needs the person themselves (a setup script that waits for a key press, a token \
    or password to paste, a sign-in prompt), run it with terminal.run. Otto opens that terminal \
    in the work panel on the right of this chat, in a tab named by the result's title, and the \
    person types straight into it; hidden input such as passwords never reaches you. Tell them \
    exactly where to look and what to do, for example: "Click into the Setup script terminal in \
    the panel on the right and follow its prompts." If terminal.wait returns waitingForUser, the \
    command is waiting on them: say so, then wait again.

    You can coordinate other Otto agents when the user asks you to delegate or chain \
    work: agent.spawn creates a new agent (choose the provider the user named), \
    agent.send_prompt hands work or results to an existing agent by its node ID, and \
    agent.get_result reads what it produced. To wait for another agent, call event.wait with \
    the target nodeID and types ["agent.run_completed", "agent.run_failed"] — never poll \
    agent.get_status in a loop. Write shared artifacts like plans to a file with \
    docs.create so the user can find them in Documents; use docs.read to share their content with agents. Delegation is rate-limited; if \
    a limit error appears, stop and report progress to the user instead of retrying. For \
    multi-step contracts with review rounds, persist the plan with the orchestration.* tools.
    """

  static func mcpConfigJSON(command: String, environment: [String: String] = [:]) -> String? {
    var server: [String: Any] = ["command": command]
    if !environment.isEmpty { server["env"] = environment }
    let config: [String: Any] = ["mcpServers": [OttoMCPRegistration.serverName: server]]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

public struct CodexAdapter: AgentAdapter {
  public let provider = AgentProvider.codex
  private let executablePath: String?
  private let homeDirectory: String

  public init(executablePath: String? = nil, homeDirectory: String = NSHomeDirectory()) {
    self.executablePath = executablePath
    self.homeDirectory = homeDirectory
  }

  public func detectInstallation() async -> InstallationStatus {
    let candidates = executablePath.map { [$0] } ?? Self.executableCandidates()
    guard let installation = await ExecutableLocator.firstWorking(candidates: candidates) else {
      return .missing(
        remediation:
          "Install or repair the OpenAI Codex CLI, then authenticate it once in Terminal before launching Otto."
      )
    }
    return .installed(
      path: installation.path,
      version: installation.version
    )
  }

  /// Use the desktop app's supported launcher before a separately installed CLI. Recent
  /// desktop versions moved it into codex-cli/bin; the wrapper supplies its bundled resources.
  /// Keep the old layout and PATH as fallbacks for older or CLI-only installations.
  static func executableCandidates(
    applicationDirectories: [String] = ["/Applications", NSHomeDirectory() + "/Applications"],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory()
  ) -> [String] {
    let bundled = applicationDirectories.flatMap { directory in
      [
        "\(directory)/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "\(directory)/ChatGPT.app/Contents/Resources/codex",
      ]
    }
    return ExecutableLocator.candidates(
      "codex", environment: environment, homeDirectory: homeDirectory, preferredPaths: bundled)
  }

  public func availableModels() async -> [AgentModel] {
    await discoverLiveModels() ?? []
  }

  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await discoverLiveModels(environment: environment) ?? []
  }

  /// Query Codex's authenticated app-server without starting an inference turn. In particular,
  /// a newly connected account does not need to run a conversation to populate its cache.
  public func discoverLiveModels(environment: [String: String] = [:]) async -> [AgentModel]? {
    // API-key profiles must not read the Mac login's app-server catalog.
    if environment["CODEX_HOME"] == nil,
      environment["CODEX_API_KEY"] != nil || environment["OPENAI_API_KEY"] != nil
    {
      return nil
    }
    guard case .installed(let path, _) = await detectInstallation() else { return nil }
    var environment = environment
    if environment["CODEX_HOME"] == nil {
      environment["CODEX_HOME"] =
        URL(fileURLWithPath: homeDirectory)
        .appending(path: ".codex").path
    }
    return await LiveModelCatalog.discover(
      provider: .codex, executable: path, environment: environment)
  }

  /// Native catalogue discovery only; does not start an inference turn or import credentials.
  public func discoverMarketplaceApps(environment: [String: String] = [:]) async
    -> [ProviderMarketplaceApp]?
  {
    if environment["CODEX_API_KEY"] != nil || environment["OPENAI_API_KEY"] != nil {
      return nil
    }
    guard case .installed(let path, _) = await detectInstallation() else { return nil }
    var environment = environment
    if environment["CODEX_HOME"] == nil {
      environment["CODEX_HOME"] = URL(fileURLWithPath: homeDirectory).appending(path: ".codex").path
    }
    return await LiveModelCatalog.discoverApps(executable: path, environment: environment)
  }

  /// Read-only cache inspection. Interactive model pickers use live discovery instead.
  public func discoverModels(environment: [String: String] = [:]) -> [AgentModel]? {
    // An explicit API key has no authenticated CLI cache of its own. Never borrow the
    // machine login's cache and present its entitlements as this key's catalog.
    if environment["CODEX_HOME"] == nil,
      environment["CODEX_API_KEY"] != nil || environment["OPENAI_API_KEY"] != nil
    {
      return nil
    }
    let codexHome =
      environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? URL(fileURLWithPath: homeDirectory, isDirectory: true).appending(path: ".codex")
    let file = codexHome.appending(path: "models_cache.json")
    guard let data = try? Data(contentsOf: file) else { return nil }
    let models = Self.parseModelsCache(data)
    return models.isEmpty ? nil : models
  }

  public static func parseModelsCache(_ data: Data) -> [AgentModel] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = root["models"] as? [[String: Any]]
    else { return [] }
    var seen = Set<String>()
    return rows.compactMap { row in
      guard let id = row["slug"] as? String, id.hasPrefix("gpt-"),
        row["visibility"] as? String != "hidden", seen.insert(id).inserted
      else { return nil }
      let display = (row["display_name"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      return AgentModel(id: id, displayName: display?.isEmpty == false ? display! : id)
    }
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, _) = await detectInstallation() else {
      throw RuntimeError.launchFailed("Codex CLI is not installed")
    }
    guard request.executionStrategy.isSupported(by: .codex) else {
      throw RuntimeError.launchFailed(
        "Scripted workflows are currently available only for Claude Code")
    }
    var arguments: [String] = []
    if let prompt = request.prompt {
      if let sessionID = request.resumeSessionID {
        arguments += ["exec", "resume", "--json", "--skip-git-repo-check"]
        appendResumeSandboxConfig(for: request.permissionMode, to: &arguments)
        if let model = request.model { arguments += ["--model", model] }
        if let effort = request.effort {
          arguments += ["--config", "model_reasoning_effort=\(effort)"]
        }
        appendOttoMCPConfig(for: request, to: &arguments)
        appendDeveloperInstructions(for: request, to: &arguments)
        arguments += [
          sessionID,
          codexPrompt(prompt, strategy: request.executionStrategy),
        ]
      } else {
        arguments += ["exec", "--json", "--skip-git-repo-check"]
        appendSandbox(for: request.permissionMode, to: &arguments)
        if let model = request.model { arguments += ["--model", model] }
        if let effort = request.effort {
          arguments += ["--config", "model_reasoning_effort=\(effort)"]
        }
        appendOttoMCPConfig(for: request, to: &arguments)
        appendDeveloperInstructions(for: request, to: &arguments)
        arguments.append(codexPrompt(prompt, strategy: request.executionStrategy))
      }
    } else if let sessionID = request.resumeSessionID {
      arguments += ["resume"]
      appendSandbox(for: request.permissionMode, to: &arguments)
      if let model = request.model { arguments += ["--model", model] }
      if let effort = request.effort {
        arguments += ["--config", "model_reasoning_effort=\(effort)"]
      }
      appendOttoMCPConfig(for: request, to: &arguments)
      appendDeveloperInstructions(for: request, to: &arguments)
      arguments.append(sessionID)
    } else {
      appendSandbox(for: request.permissionMode, to: &arguments)
      if let model = request.model { arguments += ["--model", model] }
      if let effort = request.effort {
        arguments += ["--config", "model_reasoning_effort=\(effort)"]
      }
      appendOttoMCPConfig(for: request, to: &arguments)
      appendDeveloperInstructions(for: request, to: &arguments)
    }
    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      // Otto Dev is often launched from Codex Desktop or a Codex shell. Inheriting that parent's
      // CODEX_THREAD_ID makes `codex exec` append the workspace prompt and image to the desktop task
      // instead of creating/resuming this node's own session.
      inheritedEnvironmentPrefixesToRemove: ["CODEX_"],
      workingDirectory: request.workspacePath
    )
  }

  private func codexPrompt(_ prompt: String, strategy: AgentExecutionStrategy) -> String {
    if strategy == .delegated {
      return """
        Execution strategy: delegated. Use native Codex subagents for independent workstreams when \
        useful, then synthesize and verify their results before completing the task.

        \(prompt)
        """
    }
    return prompt
  }

  /// Codex accepts per-launch developer instructions through its config layer. This is the same
  /// role separation Buzz's ACP harness uses: durable Otto/profile context is model-visible as a
  /// developer message, while the positional prompt remains exactly the user's chat message.
  /// Apply this on every launch because a bot's instructions may be edited between turns and the
  /// Codex resume protocol does not otherwise guarantee that current instructions win.
  private func appendDeveloperInstructions(
    for request: AgentLaunchRequest,
    to arguments: inout [String]
  ) {
    let profile = request.profileInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    let bootstrap = request.memoryBootstrap?.trimmingCharacters(in: .whitespacesAndNewlines)
    let includeProfile: String? = profile.flatMap { value -> String? in
      guard !value.isEmpty, bootstrap?.contains(value) != true else { return nil }
      return value
    }
    let instructions = [ClaudeCodeAdapter.ottoWorkspaceGuidance, includeProfile, bootstrap]
      .compactMap { value in value?.isEmpty == false ? value : nil }
      .joined(separator: "\n\n")
    guard !instructions.isEmpty else { return }
    arguments += [
      "--config", "developer_instructions=\"\(tomlEscaped(instructions))\"",
    ]
  }

  private func appendOttoMCPConfig(for request: AgentLaunchRequest, to arguments: inout [String]) {
    guard let mcpExecutable = request.ottoMCPExecutable else { return }
    arguments += ["--config", "mcp_servers.otto.command=\"\(tomlEscaped(mcpExecutable))\""]
    // agent.ask_user and permission approvals block on a human answer, so the otto server's
    // tool timeout must be hour-scale rather than Codex's default of about a minute.
    arguments += ["--config", "mcp_servers.otto.tool_timeout_sec=3600"]
    // Otto confirms its own consequential tools (smtp.send, gmail.send, ...) through the in-chat
    // permission card. Without this, non-interactive Codex runs refuse those calls outright
    // ("requires approval, but approval policy is never") before Otto can ask. Only those tools
    // are pre-approved, keyed by their raw MCP name; every other Otto tool keeps Codex's own
    // approval policy, and read-only runs pre-approve nothing.
    if request.permissionMode != .readOnly, !request.ottoSelfConfirmingTools.isEmpty {
      let entries = request.ottoSelfConfirmingTools.map { name in
        "\"\(tomlEscaped(name))\"={approval_mode=\"approve\"}"
      }
      arguments += ["--config", "mcp_servers.otto.tools={\(entries.joined(separator: ","))}"]
    }
    // Codex spawns MCP servers with a whitelisted environment, so the parent process's OTTO_*
    // variables never reach the bridge unless they are configured explicitly per server.
    for key in request.controlEnvironment.keys.sorted() {
      guard let value = request.controlEnvironment[key] else { continue }
      arguments += [
        "--config", "mcp_servers.otto.env.\(key)=\"\(tomlEscaped(value))\"",
      ]
    }
  }

  private func tomlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
  }

  private func appendSandbox(
    for permissionMode: AgentPermissionMode,
    to arguments: inout [String]
  ) {
    switch permissionMode {
    case .readOnly: arguments += ["--sandbox", "read-only"]
    case .workspaceWrite: arguments += ["--sandbox", "workspace-write"]
    case .unrestricted: arguments += ["--sandbox", "danger-full-access"]
    }
  }

  private func appendResumeSandboxConfig(
    for permissionMode: AgentPermissionMode,
    to arguments: inout [String]
  ) {
    let mode =
      switch permissionMode {
      case .readOnly: "read-only"
      case .workspaceWrite: "workspace-write"
      case .unrestricted: "danger-full-access"
      }
    arguments += ["--config", "sandbox_mode=\"\(mode)\""]
  }
}

/// Otto-owned multi-provider runtime. Unlike a CLI harness, this adapter places the bot's authored
/// instructions in the provider's literal system channel and refreshes them on every turn.
public struct OpenAIDirectAdapter: AgentAdapter {
  public let provider = AgentProvider.openAI
  private let executablePath: String?
  private let credentialProvider: @Sendable (OttoHarnessProvider) async throws -> String?
  /// The defaults suite the saved local server is read from; tests pass an isolated one.
  private let localDefaultsSuite: String?
  private var localDefaults: UserDefaults {
    localDefaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public init(
    executablePath: String? = nil,
    credentialProvider: @escaping @Sendable (OttoHarnessProvider) async throws -> String? =
      OpenAIDirectAdapter.defaultCredential,
    localDefaultsSuite: String? = nil
  ) {
    self.executablePath = executablePath
    self.credentialProvider = credentialProvider
    self.localDefaultsSuite = localDefaultsSuite
  }

  /// Source-compatible convenience for callers and tests written for the original OpenAI-only
  /// direct runtime.
  public init(
    executablePath: String? = nil,
    apiKeyProvider: @escaping @Sendable () async throws -> String?
  ) {
    self.executablePath = executablePath
    self.credentialProvider = { _ in try await apiKeyProvider() }
    self.localDefaultsSuite = nil
  }

  /// Reads the provider credential from the default secret store. Platforms without the
  /// keychain-backed store (the Linux daemon) have no stored credential.
  @Sendable public static func defaultCredential(for provider: OttoHarnessProvider) async throws
    -> String?
  {
    #if canImport(OttoSecurity)
      try await makeDefaultSecretStore().value(for: provider.credentialKey)
    #else
      nil
    #endif
  }

  public func detectInstallation() async -> InstallationStatus {
    let bundled = Bundle.main.executableURL?.deletingLastPathComponent()
      .appending(path: "otto-openai-agent").path
    let candidates =
      executablePath.map { [$0] }
      ?? ExecutableLocator.candidates(
        "otto-openai-agent", preferredPaths: bundled.map { [$0] } ?? [])
    guard let installation = await ExecutableLocator.firstWorking(candidates: candidates) else {
      return .missing(
        remediation: "Reinstall Otto so the bundled OpenAI API runtime is available.")
    }
    return .installed(path: installation.path, version: installation.version)
  }

  public func availableModels() async -> [AgentModel] {
    let fallback = AgentModelCatalog.options(for: .openAI)
    return await withTaskGroup(of: [AgentModel].self) { group in
      for modelProvider in OttoHarnessProvider.allCases {
        group.addTask {
          if modelProvider == .local {
            guard let configuration = LocalModelConfiguration.load(defaults: localDefaults) else {
              return []
            }
            let storedKey = try? await credentialProvider(.local)
            let configured = configuration.modelIDs.map {
              AgentModel(
                id: OttoHarnessModelSelection.persistedID(provider: .local, modelID: $0),
                displayName: "Local · \($0)")
            }
            let discovered =
              await Self.discoverDirectModels(
                provider: .local, apiKey: storedKey ?? "") ?? []
            return configured.filter { model in !discovered.contains { $0.id == model.id } }
              + discovered
          }
          guard
            let key = try? await credentialProvider(modelProvider),
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else {
            return fallback.filter {
              OttoHarnessModelSelection.resolve($0.id).provider == modelProvider
            }
          }
          return await Self.discoverDirectModels(
            provider: modelProvider, apiKey: key)
            ?? fallback.filter {
              OttoHarnessModelSelection.resolve($0.id).provider == modelProvider
            }
        }
      }
      var result: [AgentModel] = []
      for await models in group { result.append(contentsOf: models) }
      return result.sorted {
        if OttoHarnessModelSelection.resolve($0.id).provider.rawValue
          != OttoHarnessModelSelection.resolve($1.id).provider.rawValue
        {
          return OttoHarnessModelSelection.resolve($0.id).provider.rawValue
            < OttoHarnessModelSelection.resolve($1.id).provider.rawValue
        }
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedDescending
      }
    }
  }

  /// `local` lets Settings list a server's models before its address is saved.
  public static func discoverDirectModels(
    provider: OttoHarnessProvider,
    apiKey: String,
    local: LocalModelConfiguration? = nil,
    session: URLSession = .shared
  ) async -> [AgentModel]? {
    let endpoint: URL
    switch provider {
    case .openAI: endpoint = URL(string: "https://api.openai.com/v1/models")!
    case .anthropic: endpoint = URL(string: "https://api.anthropic.com/v1/models?limit=100")!
    case .xAI: endpoint = URL(string: "https://api.x.ai/v1/models")!
    case .moonshot, .deepSeek, .mistral, .groq, .gemini, .openRouter:
      guard let vendor = provider.compatibleVendor else { return nil }
      endpoint = vendor.modelsURL
    case .local:
      guard let configuration = local ?? LocalModelConfiguration.load() else { return nil }
      endpoint = configuration.modelsURL
    }
    var request = URLRequest(url: endpoint, timeoutInterval: 12)
    if provider == .anthropic {
      request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    } else if !apiKey.isEmpty {
      request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    guard let (data, response) = try? await session.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return nil }
    let models = parseDirectModels(data, provider: provider)
    return models.isEmpty ? nil : models
  }

  public static func parseDirectModels(_ data: Data, provider: OttoHarnessProvider) -> [AgentModel]
  {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = root["data"] as? [[String: Any]]
    else { return [] }
    var seen = Set<String>()
    return rows.compactMap { row in
      guard let listed = row["id"] as? String else { return nil }
      let id = provider.compatibleVendor?.modelID(fromListedID: listed) ?? listed
      guard Self.isConversationalModel(id, provider: provider), seen.insert(id).inserted
      else { return nil }
      let providerName = provider.displayName
      let suppliedName = row["display_name"] as? String
      let name = suppliedName?.isEmpty == false ? suppliedName! : id
      return AgentModel(
        id: OttoHarnessModelSelection.persistedID(provider: provider, modelID: id),
        displayName: "\(providerName) · \(name)")
    }
  }

  private static func isConversationalModel(_ id: String, provider: OttoHarnessProvider) -> Bool {
    switch provider {
    case .openAI: id.hasPrefix("gpt-5")
    case .anthropic: id.hasPrefix("claude-")
    case .xAI: id.hasPrefix("grok-4")
    case .moonshot, .deepSeek, .mistral, .groq, .gemini, .openRouter:
      provider.compatibleVendor?.isConversationalModel(id) ?? false
    case .local: !id.isEmpty && id.count <= 200 && !id.contains("\n")
    }
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, _) = await detectInstallation() else {
      throw RuntimeError.launchFailed("Otto's owned agent runtime is unavailable")
    }
    guard request.executionStrategy.isSupported(by: .openAI) else {
      throw RuntimeError.launchFailed("Otto Harness bots do not support scripted workflows")
    }
    var selection = OttoHarnessModelSelection.resolve(request.model)
    // An account's own backend key wins; otherwise fall back to the Mac-wide Models key.
    var apiKey = request.account?.harnessCredentials[selection.provider.credentialKey]
    if apiKey == nil { apiKey = try await credentialProvider(selection.provider) }
    apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    // A bot with no model chosen defaults to OpenAI. On a Mac set up only for a local server,
    // use that server's default model instead of failing for a missing OpenAI key.
    if (request.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      apiKey?.isEmpty != false, let local = LocalModelConfiguration.load(defaults: localDefaults)
    {
      selection = OttoHarnessModelSelection(provider: .local, modelID: local.modelID)
      apiKey = try await credentialProvider(.local)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard selection.provider == .local || (apiKey?.isEmpty == false) else {
      throw RuntimeError.launchFailed(
        "\(selection.provider.displayName) API key is missing. Add it in Otto Settings → Models, then retry."
      )
    }
    let localConfiguration: LocalModelConfiguration?
    if selection.provider == .local {
      guard let configured = LocalModelConfiguration.load(defaults: localDefaults) else {
        throw RuntimeError.launchFailed(
          "Local server URL and model are missing. Configure them in Otto Settings → Models.")
      }
      localConfiguration = configured
    } else {
      localConfiguration = nil
    }
    var arguments: [String] = []
    if let prompt = request.prompt {
      arguments += ["--prompt-base64", Data(prompt.utf8).base64EncodedString()]
      arguments += [
        "--system-base64",
        Data(systemInstructions(for: request).utf8).base64EncodedString(),
      ]
      arguments += ["--backend", selection.provider.rawValue]
      arguments += ["--model", selection.modelID]
      if let effort = request.effort { arguments += ["--effort", effort] }
      if let sessionID = request.resumeSessionID {
        arguments += ["--session-id", sessionID]
      }
    } else {
      arguments.append("--idle")
    }
    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      environment: [
        "OTTO_MODEL_API_KEY": apiKey ?? "",
        "OTTO_MODEL_BASE_URL": localConfiguration?.baseURL.absoluteString ?? "",
      ],
      workingDirectory: request.workspacePath
    )
  }

  func systemInstructions(for request: AgentLaunchRequest) -> String {
    let profile = request.profileInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    let bootstrap = request.memoryBootstrap?.trimmingCharacters(in: .whitespacesAndNewlines)
    let includeProfile: String? = profile.flatMap { value -> String? in
      guard !value.isEmpty, bootstrap?.contains(value) != true else { return nil }
      return "BOT INSTRUCTIONS (authoritative):\n\(value)"
    }
    return [
      includeProfile,
      request.executionStrategy == .delegated
        ? "Execution strategy: delegated. Use Otto agent.spawn for independent work, then event.wait and agent.get_result to collect and verify results before completing. This harness delegates through Otto tools."
        : nil,
      ClaudeCodeAdapter.ottoWorkspaceGuidance,
      bootstrap,
    ]
    .compactMap { value in value?.isEmpty == false ? value : nil }
    .joined(separator: "\n\n")
  }
}

public struct HermesAdapter: AgentAdapter {
  public let provider = AgentProvider.hermes
  private let executablePath: String?
  private let bridgePath: String?
  private let configurationProvider: @Sendable () -> HermesConnectionConfiguration

  public init(
    executablePath: String? = nil,
    bridgePath: String? = nil,
    configurationProvider: @escaping @Sendable () -> HermesConnectionConfiguration = {
      HermesConnectionConfiguration.load()
    }
  ) {
    self.executablePath = executablePath
    self.bridgePath = bridgePath
    self.configurationProvider = configurationProvider
  }

  public func detectInstallation() async -> InstallationStatus {
    let configuration = configurationProvider()
    switch configuration.mode {
    case .local:
      guard let installation = await localInstallation() else {
        return .missing(
          remediation:
            "Install Hermes Agent, run `hermes setup`, and authenticate it once in Terminal."
        )
      }
      return .installed(path: installation.path, version: installation.version)
    case .remote:
      guard configuration.normalizedRemoteURL != nil else {
        return .missing(remediation: "Enter a valid Hermes remote backend URL in Agent settings.")
      }
      guard let bridge = resolvedBridgePath() else {
        return .missing(remediation: "Reinstall Otto so its Hermes gateway bridge is available.")
      }
      let arguments = [
        "--mode", "remote", "--remote-url", configuration.remoteURL, "--probe",
      ]
      guard
        let version = await ExecutableLocator.version(executable: bridge, arguments: arguments)
      else {
        return .missing(
          remediation:
            "Check the remote URL and saved session token, then use Test connection in Agent settings."
        )
      }
      return .installed(path: bridge, version: version)
    }
  }

  public func availableModels() async -> [AgentModel] { [] }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard request.permissionMode != .readOnly else {
      throw RuntimeError.launchFailed(
        "Hermes does not currently expose a strict read-only mode; choose Ask to approve or Bypass permissions."
      )
    }
    let configuration = configurationProvider()
    switch configuration.mode {
    case .local:
      guard let installation = await localInstallation() else {
        throw RuntimeError.launchFailed("Hermes Agent is not installed")
      }
      if request.prompt == nil {
        var arguments = ["--tui"]
        if let sessionID = request.resumeSessionID { arguments += ["--resume", sessionID] }
        if request.permissionMode == .unrestricted { arguments.append("--yolo") }
        return ProcessLaunchSpec(
          executable: installation.path,
          arguments: arguments,
          workingDirectory: request.workspacePath
        )
      }
      guard let bridge = resolvedBridgePath() else {
        throw RuntimeError.launchFailed("Otto's Hermes bridge is unavailable")
      }
      return ProcessLaunchSpec(
        executable: bridge,
        arguments: bridgeArguments(
          mode: .local,
          request: request,
          hermesPath: installation.path,
          remoteURL: nil,
          workingDirectory: request.workspacePath
        ),
        workingDirectory: request.workspacePath
      )
    case .remote:
      guard configuration.normalizedRemoteURL != nil else {
        throw RuntimeError.launchFailed("Hermes remote URL is invalid")
      }
      guard let bridge = resolvedBridgePath() else {
        throw RuntimeError.launchFailed("Otto's Hermes gateway bridge is unavailable")
      }
      let remoteDirectory = configuration.remoteWorkingDirectory
      return ProcessLaunchSpec(
        executable: bridge,
        arguments: bridgeArguments(
          mode: .remote,
          request: request,
          hermesPath: nil,
          remoteURL: configuration.remoteURL,
          profile: configuration.remoteProfile,
          workingDirectory: remoteDirectory,
          localWorkingDirectory: request.workspacePath
        ),
        workingDirectory: request.workspacePath
      )
    }
  }

  private func localInstallation() async -> (path: String, version: String)? {
    let candidates = executablePath.map { [$0] } ?? ExecutableLocator.candidates("hermes")
    return await ExecutableLocator.firstWorking(candidates: candidates)
  }

  private func resolvedBridgePath() -> String? {
    if let bridgePath, FileManager.default.isExecutableFile(atPath: bridgePath) {
      return bridgePath
    }
    let bundled = Bundle.main.executableURL?.deletingLastPathComponent()
      .appending(path: "otto-hermes-bridge").path
    return ExecutableLocator.find(
      "otto-hermes-bridge",
      preferredPaths: bundled.map { [$0] } ?? []
    )
  }

  private func bridgeArguments(
    mode: HermesConnectionMode,
    request: AgentLaunchRequest,
    hermesPath: String?,
    remoteURL: String?,
    profile: String? = nil,
    workingDirectory: String,
    localWorkingDirectory: String? = nil
  ) -> [String] {
    var arguments = ["--mode", mode.rawValue]
    if let hermesPath { arguments += ["--hermes-path", hermesPath] }
    if let remoteURL { arguments += ["--remote-url", remoteURL] }
    if let profile, !profile.isEmpty { arguments += ["--profile", profile] }
    if !workingDirectory.isEmpty { arguments += ["--working-directory", workingDirectory] }
    if let localWorkingDirectory, !localWorkingDirectory.isEmpty {
      arguments += ["--local-working-directory", localWorkingDirectory]
    }
    let usesOttoToolTunnel =
      request.ottoMCPExecutable != nil
      && OttoEnvironment.value("CONTROL_SOCKET", in: request.controlEnvironment) != nil
      && OttoEnvironment.value("CONTROL_TOKEN", in: request.controlEnvironment) != nil
    if usesOttoToolTunnel { arguments.append("--otto-tool-tunnel") }
    if let prompt = request.prompt {
      // Hermes has no separate instruction channel through the gateway. Current Otto guidance
      // therefore travels on every turn, while bootstrapEmbeddedPrompt keeps durable memory and
      // profile context first-turn-only.
      let prepared = bootstrapEmbeddedPrompt(
        request,
        prompt: "\(ClaudeCodeAdapter.ottoWorkspaceGuidance)\n\n---\n\n\(prompt)"
      )
      arguments += [
        "--prompt",
        usesOttoToolTunnel ? "\(Self.ottoToolTunnelGuidance)\n\n\(prepared)" : prepared,
      ]
    }
    if let sessionID = request.resumeSessionID { arguments += ["--resume", sessionID] }
    arguments += ["--permission", request.permissionMode.rawValue]
    return arguments
  }

  /// Hermes cannot spawn Otto's local stdio MCP executable through its gateway. The bridge
  /// therefore carries selected calls back over Hermes' existing authenticated clarification
  /// channel and invokes the same scoped Otto control plane locally. The marker is intentionally
  /// obscure and the bridge independently allowlists tool names; prompt text alone never grants a
  /// capability.
  static let ottoToolTunnelGuidance = """
    You are running inside Otto and can control its visible browser and supervised terminals
    through a private tool tunnel. For website navigation or interaction, do not use Hermes'
    browser_* tools and do not open a browser on the Hermes host. For long-running local commands, use terminal.run followed by terminal.wait through this
    tunnel. Native Hermes subagents and provider-managed background jobs may use their native
    lifecycle APIs; keep their IDs and wait for explicit completion. Call your `clarify` tool with no choices and a question containing exactly one compact
    JSON request after this marker:

    \(HermesOttoToolTunnelProtocol.marker){"name":"browser.open","arguments":{"url":"https://example.com","x":0,"y":0}}

    The returned `user_response` is the Otto tool result, not a human answer. Continue calling the
    tunnel as needed. Available names and arguments:
    - node.list {}
    - browser.open {url,x,y}
    - browser.open_tab {url,nodeID?}
    - browser.get_selection {nodeID?}
    - browser.navigate {nodeID,url}
    - browser.get_state {nodeID}
    - browser.refresh/browser.back/browser.forward {nodeID}
    - browser.inspect {nodeID}
    - browser.click {nodeID,elementID,pageRevision?}
    - browser.type {nodeID,elementID,text,pageRevision?}
    - browser.scroll {nodeID,deltaX,deltaY,pageRevision?}
    - browser.screenshot {nodeID}
    - terminal.run {command,x,y,shell?}
    - terminal.wait {terminalID,timeoutMilliseconds?}
    - terminal.read_output {terminalID}
    - terminal.stop_process {terminalID}

    Re-inspect after navigation or meaningful page changes because element IDs are revision-scoped.
    When authentication, MFA, a passkey, or CAPTCHA is required, leave that exact page open in the
    Otto browser, ask the user to complete it there, and resume after their next message. Never request or
    transmit their credentials through chat or the tool tunnel. Use ordinary `clarify` questions
    without the marker only when you genuinely need an answer from the user.
    """
}

public struct KimiAdapter: AgentAdapter {
  /// Kimi's print mode does not announce a session id, so Otto has nothing to resume by id.
  /// The CLI does expose `--continue`, which reopens the previous session for the working
  /// directory, so the parser reports this token as the run's session and the adapter turns it
  /// back into `--continue`. Nodes with their own worktree get their own directory and therefore
  /// their own thread; two Kimi nodes sharing one directory would continue the same session.
  public static let continuationSessionToken = "kimi:continue"

  public let provider = AgentProvider.kimi
  private let executablePath: String?
  private let homeDirectory: String

  public init(executablePath: String? = nil, homeDirectory: String = NSHomeDirectory()) {
    self.executablePath = executablePath
    self.homeDirectory = homeDirectory
  }

  public func detectInstallation() async -> InstallationStatus {
    // The official installer drops the binary in ~/.kimi-code/bin and appends that directory to
    // the shell rc file, which a LaunchServices-started app never sources.
    let installerBin = "\(homeDirectory)/.kimi-code/bin/kimi"
    let candidates =
      executablePath.map { [$0] }
      ?? ExecutableLocator.candidates(
        "kimi",
        homeDirectory: homeDirectory,
        preferredPaths: [installerBin]
      )
    guard let installation = await ExecutableLocator.firstWorking(candidates: candidates) else {
      return .missing(
        remediation:
          "Install Kimi Code CLI (curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash), then run `kimi` once in Terminal and sign in with /login."
      )
    }
    return .installed(path: installation.path, version: installation.version)
  }

  public func availableModels() async -> [AgentModel] {
    await discoverModels() ?? AgentModelCatalog.options(for: .kimi)
  }

  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await discoverModels(environment: environment) ?? AgentModelCatalog.options(for: .kimi)
  }

  public func discoverModels(environment: [String: String] = [:]) async -> [AgentModel]? {
    guard case .installed(let path, _) = await detectInstallation(),
      let output = await ExecutableLocator.captureOutput(
        executable: path, arguments: ["provider", "list", "--json"], environment: environment,
        inheritedEnvironmentPrefixesToRemove: environment.isEmpty
          ? []
          : ProviderAccountIsolation.descriptor(for: .kimi).credentialEnvironmentVariables)
    else { return nil }
    let models = Self.parseModels(output)
    return models.isEmpty ? nil : models
  }

  public static func parseModels(_ output: String) -> [AgentModel] {
    guard let data = output.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let models = root["models"] as? [String: Any]
    else { return [] }
    return models.compactMap { id, raw in
      let row = raw as? [String: Any]
      let name = (row?["display_name"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      return AgentModel(id: id, displayName: name?.isEmpty == false ? name! : id)
    }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, _) = await detectInstallation() else {
      throw RuntimeError.launchFailed("Kimi Code CLI is not installed")
    }
    guard request.executionStrategy.isSupported(by: .kimi) else {
      throw RuntimeError.launchFailed(
        "\(request.executionStrategy.rawValue) is not supported by Kimi")
    }
    // Kimi rejects --plan, --auto, and --yolo alongside --prompt at startup: a non-interactive
    // run always uses its `auto` permission policy. Read-only would therefore be a promise Otto
    // cannot keep, so it is refused rather than silently downgraded to auto-approval.
    guard !(request.prompt != nil && request.permissionMode == .readOnly) else {
      throw RuntimeError.launchFailed(
        "Kimi's non-interactive mode always auto-approves tool calls, so it has no read-only mode; choose Ask to approve or Bypass permissions, or open Kimi's terminal to work in plan mode."
      )
    }
    var arguments: [String] = []
    switch request.resumeSessionID {
    case nil:
      break
    case Self.continuationSessionToken:
      arguments.append("--continue")
    case .some(let sessionID):
      arguments += ["--session", sessionID]
    }
    if let model = request.model { arguments += ["--model", model] }
    if let mcpExecutable = request.ottoMCPExecutable {
      registerOttoMCPServer(command: mcpExecutable, workingDirectory: request.workspacePath)
    }
    if let prompt = request.prompt {
      // --prompt is Kimi's non-interactive surface; stream-json emits one chat message per line
      // (assistant messages carrying tool_calls, then their tool results) instead of TUI repaints.
      arguments += [
        "--output-format", "stream-json",
        "--prompt", kimiPrompt(request, prompt: prompt),
      ]
    } else {
      appendInteractivePermissionArguments(for: request.permissionMode, to: &arguments)
    }
    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      workingDirectory: request.workspacePath
    )
  }

  /// Kimi has no --append-system-prompt equivalent, so current Otto guidance travels ahead of
  /// every task. The memory bootstrap remains first-turn-only to avoid duplicating durable state.
  private func kimiPrompt(_ request: AgentLaunchRequest, prompt: String) -> String {
    return bootstrapEmbeddedPrompt(
      request,
      prompt: "\(ClaudeCodeAdapter.ottoWorkspaceGuidance)\n\n---\n\n\(prompt)"
    )
  }

  /// Interactive launches keep Kimi's own approval flow: plan mode explores without editing,
  /// the default mode asks in the TUI, and --yolo approves regular tool calls. None of these may
  /// accompany --prompt, so they apply to TUI launches only.
  private func appendInteractivePermissionArguments(
    for permissionMode: AgentPermissionMode,
    to arguments: inout [String]
  ) {
    switch permissionMode {
    case .readOnly: arguments.append("--plan")
    case .workspaceWrite: break
    case .unrestricted: arguments.append("--yolo")
    }
  }

  /// Kimi takes no MCP flag: servers come from `mcp.json`, either user-level under
  /// ~/.kimi-code or project-level in the working directory. Otto writes only the project-level
  /// file and only its own `otto` entry, leaving the user's global configuration untouched. A
  /// `muse` entry written by Muse before the rename is removed; user-authored entries never are.
  ///
  /// The entry deliberately carries no `env`: the supervisor already injects OTTO_CONTROL_SOCKET,
  /// OTTO_CONTROL_TOKEN, OTTO_NODE_ID, OTTO_WORKSPACE_ID, and OTTO_MCP into the Kimi process, and
  /// a stdio MCP child inherits them. That keeps the file identical for every Kimi node, so two
  /// nodes sharing a directory cannot overwrite each other with another node's scoped token.
  func registerOttoMCPServer(command: String, workingDirectory: String) {
    guard !workingDirectory.isEmpty else { return }
    let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appending(path: ".kimi-code", directoryHint: .isDirectory)
    let file = directory.appending(path: "mcp.json")
    var root =
      (try? Data(contentsOf: file)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      } ?? [:]
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    let entry: [String: Any] = [
      "command": command,
      // agent.ask_user and permission approvals block on a human answer, so the otto server's
      // tool timeout must be hour-scale rather than Kimi's 30-second default.
      "toolTimeoutMs": 3_600_000,
    ]
    let cleaned = OttoMCPRegistration.removingLegacyEntry(
      from: servers, writtenKeys: ["command", "toolTimeoutMs"])
    if cleaned.count == servers.count,
      let existing = servers[OttoMCPRegistration.serverName] as? [String: Any],
      (existing["command"] as? String) == command,
      (existing["toolTimeoutMs"] as? Int) == 3_600_000
    {
      return
    }
    servers = cleaned
    servers[OttoMCPRegistration.serverName] = entry
    root["mcpServers"] = servers
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
  }
}

public struct CursorAdapter: AgentAdapter {
  public let provider = AgentProvider.cursor
  private let executablePath: String?
  private let homeDirectory: String

  public init(executablePath: String? = nil, homeDirectory: String = NSHomeDirectory()) {
    self.executablePath = executablePath
    self.homeDirectory = homeDirectory
  }

  public func detectInstallation() async -> InstallationStatus {
    let installerBin = "\(homeDirectory)/.local/bin/cursor-agent"
    let candidates =
      executablePath.map { [$0] }
      ?? ExecutableLocator.candidates(
        "cursor-agent",
        homeDirectory: homeDirectory,
        preferredPaths: [installerBin]
      )
    guard let installation = await ExecutableLocator.firstWorking(candidates: candidates) else {
      return .missing(
        remediation:
          "Install Cursor CLI (curl https://cursor.com/install -fsS | bash), then run `cursor-agent login` to authenticate."
      )
    }
    return .installed(path: installation.path, version: installation.version)
  }

  /// Cursor's model list is account-specific — it spans Composer, GPT, Claude, Grok, and Kimi
  /// tiers depending on the signed-in plan — so it is read from the CLI rather than hardcoded.
  /// The static catalog is the fallback when the CLI cannot be asked.
  public func availableModels() async -> [AgentModel] {
    await discoverModels() ?? AgentModelCatalog.options(for: .cursor)
  }

  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await discoverModels(environment: environment) ?? AgentModelCatalog.options(for: .cursor)
  }

  /// Asks the CLI for the account's catalog, returning nil when it could not be read.
  ///
  /// Separate from `availableModels()` because callers need to tell "discovery failed" from
  /// "discovery succeeded": collapsing both into the static fallback is what made a broken picker
  /// indistinguishable from a working one.
  public func discoverModels(environment: [String: String] = [:]) async -> [AgentModel]? {
    guard case .installed(let path, _) = await detectInstallation(),
      let output = await ExecutableLocator.captureOutput(
        executable: path, arguments: ["models"], environment: environment,
        inheritedEnvironmentPrefixesToRemove: environment.isEmpty
          ? []
          : ProviderAccountIsolation.descriptor(for: .cursor).credentialEnvironmentVariables)
    else { return nil }
    let models = Self.parseModels(output)
    return models.isEmpty ? nil : models
  }

  /// `cursor-agent models` prints "<id> - <display name>" per line, with the active and default
  /// entries annotated in parentheses. Those annotations are stripped so the id round-trips
  /// through `--model` unchanged.
  public static func parseModels(_ output: String) -> [AgentModel] {
    output.components(separatedBy: .newlines).compactMap { line in
      let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " - ")
      guard parts.count >= 2 else { return nil }
      let id = parts[0].trimmingCharacters(in: .whitespaces)
      guard !id.isEmpty, !id.contains(" ") else { return nil }
      var name = parts.dropFirst().joined(separator: " - ")
      for annotation in [" (default)", " (current)"] {
        name = name.replacingOccurrences(of: annotation, with: "")
      }
      let displayName = name.trimmingCharacters(in: .whitespaces)
      guard !displayName.isEmpty else { return nil }
      return AgentModel(id: id, displayName: displayName)
    }
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, _) = await detectInstallation() else {
      throw RuntimeError.launchFailed("Cursor CLI is not installed")
    }
    guard request.executionStrategy.isSupported(by: .cursor) else {
      throw RuntimeError.launchFailed(
        "\(request.executionStrategy.rawValue) is not supported by Cursor")
    }

    var arguments: [String] = []
    if request.prompt != nil {
      arguments = ["--print", "--output-format", "stream-json"]
    }
    // Otto owns the directory it launches agents in, so the trust prompt is answered up front
    // rather than blocking a headless run — Cursor exposes the flag Kimi does not.
    arguments.append("--trust")
    // Servers already declared in ~/.cursor/mcp.json (and the otto entry written below) would
    // otherwise wait on an approval prompt that a print-mode run cannot paint.
    arguments.append("--approve-mcps")

    switch request.resumeSessionID {
    case nil: break
    case .some(let sessionID): arguments += ["--resume", sessionID]
    }
    if let model = request.model { arguments += ["--model", model] }

    switch request.permissionMode {
    case .readOnly: arguments.append("--mode=plan")
    case .workspaceWrite: break
    case .unrestricted: arguments.append("--force")
    }

    if let mcpExecutable = request.ottoMCPExecutable {
      registerOttoMCPServer(command: mcpExecutable, workingDirectory: request.workspacePath)
    }
    if let prompt = request.prompt {
      arguments.append(cursorPrompt(request, prompt: prompt))
    }

    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      workingDirectory: request.workspacePath
    )
  }

  /// Cursor has no `--append-system-prompt`, so current Otto guidance travels ahead of every
  /// task. The memory bootstrap remains first-turn-only to avoid duplicating durable state.
  private func cursorPrompt(_ request: AgentLaunchRequest, prompt: String) -> String {
    return bootstrapEmbeddedPrompt(
      request,
      prompt: "\(ClaudeCodeAdapter.ottoWorkspaceGuidance)\n\n---\n\n\(prompt)"
    )
  }

  /// Cursor takes no MCP flag: servers come from ~/.cursor/mcp.json or the workspace's own
  /// .cursor/mcp.json. Otto writes only the project-level file and only its own `otto` entry,
  /// leaving the user's global servers untouched. A `muse` entry written by Muse before the
  /// rename is removed; user-authored entries never are.
  ///
  /// As with Kimi the entry carries no `env`: the supervisor already injects the scoped control
  /// variables into the Cursor process and a stdio MCP child inherits them, so the file stays
  /// identical for every node and two nodes in one directory cannot leak each other's token.
  func registerOttoMCPServer(command: String, workingDirectory: String) {
    guard !workingDirectory.isEmpty else { return }
    let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appending(path: ".cursor", directoryHint: .isDirectory)
    let file = directory.appending(path: "mcp.json")
    var root =
      (try? Data(contentsOf: file)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      } ?? [:]
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    let entry: [String: Any] = ["command": command]
    let cleaned = OttoMCPRegistration.removingLegacyEntry(from: servers, writtenKeys: ["command"])
    if cleaned.count == servers.count,
      let existing = servers[OttoMCPRegistration.serverName] as? [String: Any],
      (existing["command"] as? String) == command
    {
      return
    }
    servers = cleaned
    servers[OttoMCPRegistration.serverName] = entry
    root["mcpServers"] = servers
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
  }
}

public struct OpenCodeAdapter: AgentAdapter {
  public let provider = AgentProvider.openCode
  private let executablePath: String?
  private let homeDirectory: String

  public init(executablePath: String? = nil, homeDirectory: String = NSHomeDirectory()) {
    self.executablePath = executablePath
    self.homeDirectory = homeDirectory
  }

  public func detectInstallation() async -> InstallationStatus {
    // The installer writes the binary to ~/.opencode/bin and appends that directory to the shell
    // rc file, which a LaunchServices-started app never sources — the same shape as Kimi.
    let installerBin = "\(homeDirectory)/.opencode/bin/opencode"
    let candidates =
      executablePath.map { [$0] }
      ?? ExecutableLocator.candidates(
        "opencode",
        homeDirectory: homeDirectory,
        preferredPaths: [installerBin]
      )
    guard let installation = await ExecutableLocator.firstWorking(candidates: candidates) else {
      return .missing(
        remediation:
          "Install OpenCode (curl -fsSL https://opencode.ai/install | bash), then run `opencode` once and sign in with `opencode auth login`."
      )
    }
    return .installed(path: installation.path, version: installation.version)
  }

  public func availableModels() async -> [AgentModel] {
    await discoverModels() ?? []
  }

  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await discoverModels(environment: environment) ?? []
  }

  /// OpenCode lists every model on models.dev for each connected provider, hundreds of them, from
  /// a local cache it only refreshes on its own schedule. Otto refreshes that cache when it is
  /// older than this, so a model released this morning shows up without the user opening OpenCode.
  static let modelCacheMaxAge: TimeInterval = 60 * 60

  public func discoverModels(environment: [String: String] = [:]) async -> [AgentModel]? {
    guard case .installed(let path, _) = await detectInstallation() else { return nil }
    let strip =
      environment.isEmpty
      ? [] : ProviderAccountIsolation.descriptor(for: .openCode).credentialEnvironmentVariables
    func list(_ arguments: [String]) async -> [AgentModel]? {
      guard
        let output = await ExecutableLocator.captureOutput(
          executable: path, arguments: arguments, environment: environment,
          inheritedEnvironmentPrefixesToRemove: strip)
      else { return nil }
      // --verbose carries names and release dates; plain ids are the fallback for older builds.
      let verbose = Self.parseVerboseModels(output)
      let models =
        verbose.isEmpty ? Self.parseModels(output).filter { $0.id.contains("/") } : verbose
      return models.isEmpty ? nil : models
    }
    // Offline, --refresh fails; the existing cache is still better than no catalog.
    if modelCacheIsStale(environment: environment),
      let refreshed = await list(["models", "--verbose", "--refresh"])
    {
      return refreshed
    }
    return await list(["models", "--verbose"])
  }

  private func modelCacheIsStale(environment: [String: String]) -> Bool {
    let cacheRoot =
      environment["XDG_CACHE_HOME"] ?? ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
      ?? "\(homeDirectory)/.cache"
    let file = "\(cacheRoot)/opencode/models.json"
    guard
      let modified = try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate]
        as? Date
    else { return true }
    return Date().timeIntervalSince(modified) > Self.modelCacheMaxAge
  }

  /// Parses `opencode models --verbose`: each model id on its own line, followed by its metadata
  /// as a JSON object. Newest releases come first so the latest models lead a long list, and
  /// deprecated models are dropped.
  public static func parseVerboseModels(_ output: String) -> [AgentModel] {
    var entries: [(id: String, body: [String])] = []
    for line in output.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !line.hasPrefix(" "), !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("}"),
        !trimmed.contains(where: \.isWhitespace), trimmed.contains("/")
      {
        entries.append((trimmed, []))
      } else if !entries.isEmpty {
        entries[entries.count - 1].body.append(line)
      }
    }
    var seen = Set<String>()
    let parsed: [(model: AgentModel, released: String)] = entries.compactMap { entry in
      guard seen.insert(entry.id).inserted,
        let data = entry.body.joined(separator: "\n").data(using: .utf8),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { return nil }
      if let status = object["status"] as? String, status == "deprecated" { return nil }
      let provider = entry.id.split(separator: "/").first.map(String.init) ?? ""
      let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? entry.id
      return (
        AgentModel(id: entry.id, displayName: provider.isEmpty ? name : "\(name) · \(provider)"),
        object["release_date"] as? String ?? ""
      )
    }
    // ISO dates sort lexically; the stable tiebreak keeps OpenCode's own order within a day.
    return parsed.enumerated()
      .sorted { lhs, rhs in
        lhs.element.released != rhs.element.released
          ? lhs.element.released > rhs.element.released : lhs.offset < rhs.offset
      }
      .map(\.element.model)
  }

  public static func parseModels(_ output: String) -> [AgentModel] {
    var seen = Set<String>()
    return output.components(separatedBy: .newlines).compactMap { line in
      let id = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, !id.contains(where: { $0.isWhitespace }), seen.insert(id).inserted
      else { return nil }
      return AgentModel(id: id, displayName: id)
    }
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, _) = await detectInstallation() else {
      throw RuntimeError.launchFailed("OpenCode is not installed")
    }
    guard request.executionStrategy.isSupported(by: .openCode) else {
      throw RuntimeError.launchFailed(
        "\(request.executionStrategy.rawValue) is not supported by OpenCode")
    }

    var arguments: [String] = []
    if let prompt = request.prompt {
      // `run` is OpenCode's non-interactive surface and --format json emits one event per line,
      // each already carrying the session id, so continuations resume by real id rather than by
      // a working-directory guess the way Kimi's --continue must.
      arguments = ["run", "--format", "json"]
      if let sessionID = request.resumeSessionID { arguments += ["--session", sessionID] }
      if let model = request.model { arguments += ["--model", model] }
      // --auto is OpenCode's only permission flag; read-only and ask are expressed through the
      // injected config below, which is why they do not appear here.
      if request.permissionMode == .unrestricted { arguments.append("--auto") }
      arguments.append(openCodePrompt(request, prompt: prompt))
    } else {
      if let sessionID = request.resumeSessionID { arguments += ["--session", sessionID] }
      if let model = request.model { arguments += ["--model", model] }
    }

    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      environment: injectedConfiguration(request),
      workingDirectory: request.workspacePath
    )
  }

  /// OpenCode has no `--append-system-prompt`, so current Otto guidance travels ahead of every
  /// task. The memory bootstrap remains first-turn-only to avoid duplicating durable state.
  private func openCodePrompt(_ request: AgentLaunchRequest, prompt: String) -> String {
    return bootstrapEmbeddedPrompt(
      request,
      prompt: "\(ClaudeCodeAdapter.ottoWorkspaceGuidance)\n\n---\n\n\(prompt)"
    )
  }

  /// OpenCode takes no MCP flag and no permission flag beyond `--auto`, but it does read an
  /// inline config from OPENCODE_CONFIG_CONTENT, which outranks the user's global and project
  /// files and merges rather than replaces them.
  ///
  /// Otto uses that instead of writing into the workspace: nothing lands on disk, the user's own
  /// servers and settings survive, and each node's scoped token stays private to its own process
  /// — two OpenCode nodes in one directory cannot overwrite each other the way a shared config
  /// file would allow.
  private func injectedConfiguration(_ request: AgentLaunchRequest) -> [String: String] {
    var configuration: [String: Any] = [:]

    if let mcpExecutable = request.ottoMCPExecutable {
      configuration["mcp"] = [
        OttoMCPRegistration.serverName: [
          "type": "local",
          "command": [mcpExecutable],
          "enabled": true,
          // agent.ask_user and permission approvals block on a human answer, so the otto server's
          // timeout must be hour-scale rather than OpenCode's 5-second default.
          "timeout": 3_600_000,
        ] as [String: Any]
      ]
    }

    // Denying a permission removes the tool from the model's list outright rather than prompting,
    // so read-only is a real guarantee here and not a request the agent could talk its way past.
    if request.permissionMode == .readOnly {
      configuration["permission"] = [
        "edit": "deny",
        "bash": "deny",
        "webfetch": "deny",
      ]
    }

    guard !configuration.isEmpty,
      let data = try? JSONSerialization.data(
        withJSONObject: configuration, options: [.sortedKeys, .withoutEscapingSlashes]),
      let json = String(data: data, encoding: .utf8)
    else { return [:] }
    return ["OPENCODE_CONFIG_CONTENT": json]
  }
}

/// Pi (pi.dev, the `@earendil-works/pi-coding-agent` npm package) is a small Node-based coding
/// agent. Otto drives it through `--mode json`, which streams one JSONL event per line and exits
/// when the prompt is answered, resumes by real session id, appends Otto's guidance to the system
/// prompt, and registers the otto bridge through a project-level `.pi/mcp.json`.
///
/// Pi has no approval system of its own: every tool it declares runs without asking. Otto's
/// permission modes therefore map to which tools are declared, not to prompts. Read-only
/// allowlists the inspection tools only; workspace-write and unrestricted both run Pi's default
/// tool set, with Otto's `agent.ask_user` tool available for questions.
public struct PiAdapter: AgentAdapter {
  public let provider = AgentProvider.pi
  private let executablePath: String?
  private let homeDirectory: String

  public init(executablePath: String? = nil, homeDirectory: String = NSHomeDirectory()) {
    self.executablePath = executablePath
    self.homeDirectory = homeDirectory
  }

  /// The tools Pi declares for a read-only run. Pi's own documentation names these as the
  /// inspection set; MCP tools stay available because no entry starts with `mcp__`.
  public static let readOnlyTools = "read,grep,find,ls"

  public func detectInstallation() async -> InstallationStatus {
    // npm/bun global installs land in directories a LaunchServices-started app never has on PATH.
    let candidates =
      executablePath.map { [$0] }
      ?? ExecutableLocator.candidates(
        "pi",
        homeDirectory: homeDirectory,
        preferredPaths: [
          "\(homeDirectory)/.bun/bin/pi",
          "\(homeDirectory)/.npm-global/bin/pi",
          "\(homeDirectory)/.local/bin/pi",
        ] + nodeDirectories().map { "\($0)/pi" }
      )
    guard
      let installation = await ExecutableLocator.firstWorking(
        candidates: candidates, environment: launchEnvironment())
    else {
      return .missing(
        remediation:
          "Install Pi (npm install -g @earendil-works/pi-coding-agent), then run `pi` once in Terminal and sign in to a model provider with /login."
      )
    }
    return .installed(path: installation.path, version: installation.version)
  }

  public func availableModels() async -> [AgentModel] {
    await discoverModels() ?? []
  }

  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await discoverModels(environment: environment) ?? []
  }

  /// `pi --list-models` prints the models of every provider the user has signed into, so the
  /// catalog is account-specific and read live. A Pi with no credentials prints a sign-in hint
  /// and no table, which reads as "no catalog" rather than an empty picker.
  public func discoverModels(environment: [String: String] = [:]) async -> [AgentModel]? {
    guard case .installed(let path, _) = await detectInstallation() else { return nil }
    var merged = launchEnvironment()
    merged.merge(environment) { _, account in account }
    guard
      let output = await ExecutableLocator.captureOutput(
        executable: path, arguments: ["--list-models"], environment: merged)
    else { return nil }
    let models = Self.parseModels(output)
    return models.isEmpty ? nil : models
  }

  /// Parses the `--list-models` table: a header row of `provider  model  context  max-out
  /// thinking  images`, then one row per model with columns separated by two or more spaces.
  /// Ids are `provider/model`, the form `--model` accepts unambiguously.
  public static func parseModels(_ output: String) -> [AgentModel] {
    var seen = Set<String>()
    var models: [AgentModel] = []
    for line in output.components(separatedBy: .newlines) {
      let columns = line.split(separator: /\s{2,}/, omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard columns.count >= 2 else { continue }
      let provider = columns[0]
      let model = columns[1]
      guard provider != "provider", !provider.contains(where: \.isWhitespace),
        !model.contains(where: \.isWhitespace), !provider.isEmpty, !model.isEmpty
      else { continue }
      let id = "\(provider)/\(model)"
      guard seen.insert(id).inserted else { continue }
      models.append(AgentModel(id: id, displayName: "\(model) · \(provider)"))
    }
    return models
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, _) = await detectInstallation() else {
      throw RuntimeError.launchFailed("Pi is not installed")
    }
    guard request.executionStrategy.isSupported(by: .pi) else {
      throw RuntimeError.launchFailed(
        "\(request.executionStrategy.rawValue) is not supported by Pi")
    }

    var arguments: [String] = []
    if request.prompt != nil { arguments += ["--mode", "json"] }
    // `--session` accepts a session id and looks in the current project first, so a resumed
    // Otto node reopens exactly the Pi session the header announced.
    if let sessionID = request.resumeSessionID { arguments += ["--session", sessionID] }
    if let model = request.model { arguments += ["--model", model] }
    if let effort = request.effort { arguments += ["--thinking", effort] }
    if request.permissionMode == .readOnly { arguments += ["--tools", Self.readOnlyTools] }

    if let mcpExecutable = request.ottoMCPExecutable {
      registerOttoMCPServer(command: mcpExecutable, workingDirectory: request.workspacePath)
      // Project `.pi/mcp.json` is trust-gated and a JSON run cannot paint the trust prompt, so
      // the workspace is trusted for this process. Interactive Kimi and Cursor runs answer the
      // same prompt the same way; the saved trust decision in ~/.pi/agent/trust.json is untouched.
      arguments.append("--approve")
    }

    // Guidance, the bot's profile, and the memory bootstrap share one appended system prompt so
    // they reach every turn, including resumed sessions, without landing in the transcript.
    let profile = request.profileInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    let systemPrompt = [
      ClaudeCodeAdapter.ottoWorkspaceGuidance,
      profile.flatMap { $0.isEmpty ? nil : "Your role and operating instructions:\n\($0)" },
      request.memoryBootstrap,
    ]
    .compactMap { $0 }
    .joined(separator: "\n\n")
    arguments += ["--append-system-prompt", systemPrompt]

    if let prompt = request.prompt {
      arguments += ["--", Self.promptArgument(prompt, for: request.executionStrategy)]
    }

    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      environment: launchEnvironment(),
      workingDirectory: request.workspacePath
    )
  }

  /// Pi reads a leading `@` in a message argument as a file to attach, so a chat message that
  /// starts with a mention is given a plain lead-in instead of vanishing into a missing file.
  public static func promptArgument(_ prompt: String, for strategy: AgentExecutionStrategy)
    -> String
  {
    let prepared =
      strategy == .delegated
      ? "Execution strategy: delegated. Split independent work where your tools allow, wait for "
        + "real results, then synthesize and verify them.\n\n" + prompt
      : prompt
    return prepared.hasPrefix("@") ? "Task from the user:\n\(prepared)" : prepared
  }

  /// Pi is a Node program behind an `#!/usr/bin/env node` shim, so the interpreter's directory
  /// has to be on the child's PATH. A LaunchServices-started app inherits only the system PATH,
  /// which has neither Homebrew nor a version manager on it.
  func launchEnvironment(
    inheriting parent: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let existing = parent["PATH"]?.split(separator: ":").map(String.init) ?? []
    let missing = nodeDirectories().filter { !existing.contains($0) }
    guard !missing.isEmpty else { return [:] }
    return ["PATH": (existing + missing).joined(separator: ":")]
  }

  /// Directories that hold a `node` binary, newest version-manager install first.
  private func nodeDirectories() -> [String] {
    let manager = FileManager.default
    var directories: [String] = []
    let nvmRoot = "\(homeDirectory)/.nvm/versions/node"
    let nvmVersions = ((try? manager.contentsOfDirectory(atPath: nvmRoot)) ?? [])
      .filter { $0.hasPrefix("v") }
      .sorted { lhs, rhs in
        lhs.dropFirst().split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes(
          rhs.dropFirst().split(separator: ".").compactMap { Int($0) }) == false
      }
    directories += nvmVersions.map { "\(nvmRoot)/\($0)/bin" }
    directories += [
      "\(homeDirectory)/.volta/bin", "\(homeDirectory)/.local/share/fnm/aliases/default/bin",
      "/opt/homebrew/bin", "/usr/local/bin",
    ]
    return directories.filter { manager.isExecutableFile(atPath: "\($0)/node") }
  }

  /// Pi takes no MCP flag: servers come from `mcp.json`, user-level under ~/.pi/agent or
  /// project-level in `.pi/`. Otto writes only the project file and only its own `otto` entry,
  /// leaving the user's global configuration untouched.
  ///
  /// Pi starts stdio servers with a minimal environment rather than its own, so the entry names
  /// the control variables explicitly as `${OTTO_…}` placeholders that Pi resolves from its
  /// process environment at connect time. The file therefore stays identical for every Pi node
  /// and carries no token, so two nodes sharing a directory cannot overwrite each other with
  /// another node's scoped credentials.
  func registerOttoMCPServer(command: String, workingDirectory: String) {
    guard !workingDirectory.isEmpty else { return }
    let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appending(path: ".pi", directoryHint: .isDirectory)
    let file = directory.appending(path: "mcp.json")
    var root =
      (try? Data(contentsOf: file)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      } ?? [:]
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    let entry = Self.ottoServerEntry(command: command)
    let cleaned = OttoMCPRegistration.removingLegacyEntry(
      from: servers, writtenKeys: Set(entry.keys))
    if cleaned.count == servers.count,
      let existing = servers[OttoMCPRegistration.serverName] as? [String: Any],
      NSDictionary(dictionary: existing).isEqual(to: entry)
    {
      return
    }
    servers = cleaned
    servers[OttoMCPRegistration.serverName] = entry
    root["mcpServers"] = servers
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
  }

  static func ottoServerEntry(command: String) -> [String: Any] {
    [
      "command": command,
      // Only variables every Otto launch sets: an unresolvable placeholder stops the server.
      "env": Dictionary(
        uniqueKeysWithValues: [
          "OTTO_CONTROL_SOCKET", "OTTO_CONTROL_TOKEN", "OTTO_NODE_ID", "OTTO_WORKSPACE_ID",
        ].map { ($0, "${\($0)}") }),
      // agent.ask_user blocks on a human answer, so the per-request timeout (seconds) must be
      // hour-scale rather than Pi's 60-second default.
      "timeout": 3_600,
      "description": "Otto: the app this agent runs in (browser, documents, chat, memory).",
    ]
  }
}

public struct GrokAdapter: AgentAdapter {
  public let provider = AgentProvider.grok
  private let executablePath: String?
  private let homeDirectory: String

  public init(executablePath: String? = nil, homeDirectory: String = NSHomeDirectory()) {
    self.executablePath = executablePath
    self.homeDirectory = homeDirectory
  }

  public func detectInstallation() async -> InstallationStatus {
    // The installer writes to ~/.grok/bin and often also ~/.local/bin. A LaunchServices-started
    // app never sources the shell rc that appends those directories to PATH.
    let installerBins = [
      "\(homeDirectory)/.grok/bin/grok",
      "\(homeDirectory)/.local/bin/grok",
    ]
    let candidates =
      executablePath.map { [$0] }
      ?? ExecutableLocator.candidates(
        "grok",
        homeDirectory: homeDirectory,
        preferredPaths: installerBins
      )
    guard let installation = await ExecutableLocator.firstWorking(candidates: candidates) else {
      return .missing(
        remediation:
          "Install Grok (curl -fsSL https://x.ai/cli/install.sh | bash), then run `grok login` once in Terminal."
      )
    }
    return .installed(path: installation.path, version: installation.version)
  }

  public func availableModels() async -> [AgentModel] {
    await discoverModels() ?? AgentModelCatalog.options(for: .grok)
  }

  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await discoverModels(environment: environment) ?? AgentModelCatalog.options(for: .grok)
  }

  public func discoverModels(environment: [String: String] = [:]) async -> [AgentModel]? {
    guard case .installed(let path, _) = await detectInstallation(),
      let output = await ExecutableLocator.captureOutput(
        executable: path, arguments: ["models"], environment: environment,
        inheritedEnvironmentPrefixesToRemove: environment.isEmpty
          ? []
          : ProviderAccountIsolation.descriptor(for: .grok).credentialEnvironmentVariables)
    else { return nil }
    let models = Self.parseModels(output)
    return models.isEmpty ? nil : models
  }

  /// `grok models` prints a header, then rows like `* grok-4.6 (default)` and `- grok-4.5`.
  public static func parseModels(_ output: String) -> [AgentModel] {
    output.components(separatedBy: .newlines).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("*") || trimmed.hasPrefix("-") else { return nil }
      let token = trimmed.drop(while: { $0 == "*" || $0 == "-" || $0.isWhitespace })
      let idEnd = token.firstIndex(where: \.isWhitespace) ?? token.endIndex
      let id = String(token[token.startIndex..<idEnd])
      guard !id.isEmpty, id.contains(where: \.isLetter) else { return nil }
      let displayName = id.replacingOccurrences(of: "-", with: " ").capitalized
      return AgentModel(id: id, displayName: displayName)
    }
  }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed(let path, _) = await detectInstallation() else {
      throw RuntimeError.launchFailed("Grok is not installed")
    }
    guard request.executionStrategy.isSupported(by: .grok) else {
      throw RuntimeError.launchFailed(
        "\(request.executionStrategy.rawValue) is not supported by Grok")
    }

    var arguments: [String] = []
    if request.prompt != nil {
      // streaming-messages-json is the Messages API stream-json shape Claude's parser already
      // understands: system/init announces session_id, assistant/user carry tool use, result
      // ends the turn. --include-partial-messages adds text/thinking deltas for live chat.
      arguments = [
        "--output-format", "streaming-messages-json",
        "--include-partial-messages",
        "--disallowed-tools", "ask_user_question",
      ]
    }

    switch request.resumeSessionID {
    case nil: break
    case .some(let sessionID): arguments += ["--resume", sessionID]
    }
    if let model = request.model { arguments += ["--model", model] }
    if let effort = request.effort { arguments += ["--effort", effort] }

    switch request.permissionMode {
    case .readOnly:
      arguments += ["--permission-mode", "plan", "--sandbox", "read-only"]
    case .workspaceWrite:
      arguments += ["--permission-mode", "default", "--sandbox", "workspace"]
    case .unrestricted:
      arguments += ["--permission-mode", "bypassPermissions", "--sandbox", "off"]
    }

    if let rules = systemRules(for: request) {
      arguments += ["--rules", rules]
    }
    if let mcpExecutable = request.ottoMCPExecutable {
      registerOttoMCPServer(command: mcpExecutable, workingDirectory: request.workspacePath)
    }
    if let prompt = request.prompt {
      arguments += ["-p", grokPrompt(request, prompt: prompt)]
    }

    return ProcessLaunchSpec(
      executable: path,
      arguments: arguments,
      workingDirectory: request.workspacePath
    )
  }

  /// Grok's `--rules` is the extra-system-prompt channel. Continuations still get workspace
  /// guidance so a resumed TUI stint keeps the otto tools, but skip the memory bootstrap
  /// already stored in the session.
  private func systemRules(for request: AgentLaunchRequest) -> String? {
    var parts = [ClaudeCodeAdapter.ottoWorkspaceGuidance]
    if request.resumeSessionID == nil, let bootstrap = request.memoryBootstrap {
      parts.append(bootstrap)
    }
    return parts.joined(separator: "\n\n")
  }

  private func grokPrompt(_ request: AgentLaunchRequest, prompt: String) -> String {
    guard request.executionStrategy == .delegated else { return prompt }
    return """
      Execution strategy: delegated. Use Grok subagents when the task divides into \
      independent workstreams, then synthesize and verify their results in this conversation.

      \(prompt)
      """
  }

  /// Grok takes no MCP launch flag. Project servers live in `.grok/config.toml`. Otto writes
  /// only the `otto` server there and leaves the user's ~/.grok/config.toml alone. The `muse`
  /// tables Muse wrote before the rename are removed when their command is Muse's or Otto's own
  /// MCP bridge; a user-authored `muse` server is left untouched.
  ///
  /// Env values are `${VAR}` references, expanded by Grok at load time from the process
  /// environment the supervisor already injects. The file is therefore identical for every
  /// Grok node, so two nodes in one directory cannot overwrite each other's scoped token.
  func registerOttoMCPServer(command: String, workingDirectory: String) {
    guard !workingDirectory.isEmpty else { return }
    let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      .appending(path: ".grok", directoryHint: .isDirectory)
    let file = directory.appending(path: "config.toml")
    let original = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let existing = Self.removingLegacySection(from: original)
    let section = Self.ottoMCPSection(command: command)
    if existing == original, existing.contains("[mcp_servers.otto]"),
      existing.contains("command = \(Self.tomlString(command))")
    {
      return
    }
    let next: String
    if existing.contains("[mcp_servers.otto]") {
      next = Self.replaceOttoSection(in: existing, with: section)
    } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      next = section
    } else {
      next = existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + section
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? next.write(to: file, atomically: true, encoding: .utf8)
  }

  static func ottoMCPSection(command: String) -> String {
    """
    [mcp_servers.otto]
    command = \(tomlString(command))
    tool_timeout_sec = 3600

    [mcp_servers.otto.env]
    OTTO_CONTROL_SOCKET = "${OTTO_CONTROL_SOCKET}"
    OTTO_CONTROL_TOKEN = "${OTTO_CONTROL_TOKEN}"
    OTTO_NODE_ID = "${OTTO_NODE_ID}"
    OTTO_WORKSPACE_ID = "${OTTO_WORKSPACE_ID}"
    OTTO_MCP = "${OTTO_MCP}"
    """
  }

  static func tomlString(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// Replaces the `[mcp_servers.otto]` table and any immediately following
  /// `[mcp_servers.otto.*]` subtables, leaving every other table untouched.
  static func replaceOttoSection(in existing: String, with section: String) -> String {
    let prefix = removingTables(named: OttoMCPRegistration.serverName, from: existing)
    if prefix.isEmpty { return section }
    return prefix + "\n\n" + section
  }

  /// Drops the pre-rename `[mcp_servers.muse]` tables, but only when their `command` is Muse's
  /// or Otto's own MCP bridge. Anything else under that name was written by the user.
  static func removingLegacySection(from existing: String) -> String {
    let legacy = OttoMCPRegistration.legacyServerName
    var inLegacyTable = false
    var legacyCommand: String?
    for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        inLegacyTable = trimmed == "[mcp_servers.\(legacy)]"
      } else if inLegacyTable, trimmed.hasPrefix("command"),
        let equals = trimmed.firstIndex(of: "=")
      {
        legacyCommand = trimmed[trimmed.index(after: equals)...]
          .trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
          .replacingOccurrences(of: "\\\\", with: "\\")
      }
    }
    guard let legacyCommand, OttoMCPRegistration.isOttoExecutable(legacyCommand) else {
      return existing
    }
    return removingTables(named: legacy, from: existing)
  }

  /// Removes `[mcp_servers.<server>]` and its `[mcp_servers.<server>.*]` subtables.
  private static func removingTables(named server: String, from existing: String) -> String {
    let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var output: [String] = []
    var skipping = false
    for line in lines {
      let heading = line.trimmingCharacters(in: .whitespaces)
      if heading.hasPrefix("[") && heading.hasSuffix("]") {
        let name = String(heading.dropFirst().dropLast())
        skipping = name == "mcp_servers.\(server)" || name.hasPrefix("mcp_servers.\(server).")
      }
      if !skipping { output.append(line) }
    }
    return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct ShellAdapter: AgentAdapter {
  public let provider = AgentProvider.shell
  private let executablePath: String

  public init(executablePath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
    self.executablePath = executablePath
  }

  public func detectInstallation() async -> InstallationStatus {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      return .missing(remediation: "Configure an executable login shell in Otto settings.")
    }
    return .installed(path: executablePath, version: "system")
  }

  public func availableModels() async -> [AgentModel] { [] }

  public func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    guard case .installed = await detectInstallation() else {
      throw RuntimeError.launchFailed("Configured shell is not executable")
    }
    guard request.resumeSessionID == nil else {
      throw RuntimeError.launchFailed("Shell sessions cannot be resumed")
    }
    return ProcessLaunchSpec(
      executable: executablePath,
      arguments: request.prompt.map { ["-lc", $0] } ?? ["-l"],
      workingDirectory: request.workspacePath
    )
  }
}

/// The MCP server name Otto registers with provider CLIs. Tools therefore appear to agents as
/// `mcp__otto__<tool>`. Before the rename the same server was registered as `muse`.
public enum OttoMCPRegistration {
  public static let serverName = "otto"
  public static let legacyServerName = "muse"
  public static let serverNames: Set<String> = [serverName, legacyServerName]

  /// Whether `command` is Otto's MCP bridge (or Muse's, from before the rename).
  public static func isOttoExecutable(_ command: String) -> Bool {
    ["otto-mcp", "muse-mcp"].contains(URL(fileURLWithPath: command).lastPathComponent)
  }

  /// Removes the legacy `muse` server entry when it is exactly what Muse wrote: its command is
  /// the bridge executable and it carries no keys beyond `writtenKeys`. A `muse` entry the user
  /// authored (another command, or extra settings) is kept.
  public static func removingLegacyEntry(
    from servers: [String: Any], writtenKeys: Set<String>
  ) -> [String: Any] {
    guard let entry = servers[legacyServerName] as? [String: Any],
      let command = entry["command"] as? String, isOttoExecutable(command),
      Set(entry.keys).isSubset(of: writtenKeys)
    else { return servers }
    var cleaned = servers
    cleaned[legacyServerName] = nil
    return cleaned
  }

  /// `smtp.send` → `mcp__otto__smtp_send`: Claude Code namespaces MCP tools and replaces
  /// characters outside `[A-Za-z0-9_-]` with underscores (the bridge maps them back).
  public static func claudeToolName(_ name: String) -> String {
    let sanitized = String(
      name.map { character in
        character.isLetter || character.isNumber || character == "_" || character == "-"
          ? character : "_"
      })
    return "mcp__\(serverName)__\(sanitized)"
  }

  /// `mcp__otto__agent_ask_user` → `agent_ask_user`; also strips the legacy `mcp__muse__`.
  public static func unqualifiedToolName(_ name: String) -> String? {
    for server in [serverName, legacyServerName] {
      let prefix = "mcp__\(server)__"
      if name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
    }
    return nil
  }
}
