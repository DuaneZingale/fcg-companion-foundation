import Foundation
import OttoModels

public enum InstallationStatus: Sendable, Equatable {
  case installed(path: String, version: String)
  case missing(remediation: String)
}

public struct AgentModel: Codable, Sendable, Equatable {
  public var id: String
  public var displayName: String

  public init(id: String, displayName: String) {
    self.id = id
    self.displayName = displayName
  }
}

/// Model vendors available beneath Otto's owned harness. These are model transports, not external
/// harness products: Otto continues to own instructions, memory, tools, and session history.
public enum OttoHarnessProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case openAI = "openai"
  case anthropic = "anthropic"
  case xAI = "xai"
  case moonshot = "moonshot"
  case deepSeek = "deepseek"
  case mistral = "mistral"
  case groq = "groq"
  case gemini = "gemini"
  case openRouter = "openrouter"
  case local = "local"

  public var id: String { rawValue }

  /// The OpenAI-compatible endpoint table entry, for vendors reached through chat completions.
  public var compatibleVendor: OttoHarnessCompatibleVendor? {
    OttoHarnessCompatibleVendor(rawValue: rawValue)
  }

  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .xAI: "xAI"
    case .moonshot, .deepSeek, .mistral, .groq, .gemini, .openRouter:
      compatibleVendor?.displayName ?? rawValue
    case .local: "Local (OpenAI compatible)"
    }
  }

  public var credentialKey: String {
    switch self {
    case .openAI: "openai.api-key"
    case .anthropic: "anthropic.api-key"
    case .xAI: "xai.api-key"
    case .moonshot, .deepSeek, .mistral, .groq, .gemini, .openRouter: "\(rawValue).api-key"
    case .local: "local.openai.api-key"
    }
  }
}

public struct OttoHarnessModelSelection: Equatable, Sendable {
  public var provider: OttoHarnessProvider
  public var modelID: String

  public init(provider: OttoHarnessProvider, modelID: String) {
    self.provider = provider
    self.modelID = modelID
  }

  public static func resolve(_ persistedID: String?) -> OttoHarnessModelSelection {
    let value = persistedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard let separator = value.firstIndex(of: "/"),
      let provider = OttoHarnessProvider(rawValue: String(value[..<separator]))
    else {
      // 0.1.22 and 0.1.23 stored bare GPT model IDs. Preserve those profiles losslessly.
      return OttoHarnessModelSelection(
        provider: .openAI, modelID: value.isEmpty ? "gpt-5.6" : value)
    }
    let modelID = String(value[value.index(after: separator)...])
    return OttoHarnessModelSelection(
      provider: provider, modelID: modelID.isEmpty ? defaultModel(for: provider) : modelID)
  }

  public static func persistedID(provider: OttoHarnessProvider, modelID: String) -> String {
    "\(provider.rawValue)/\(modelID)"
  }

  private static func defaultModel(for provider: OttoHarnessProvider) -> String {
    switch provider {
    case .openAI: "gpt-5.6"
    case .anthropic: "claude-sonnet-5"
    case .xAI: "grok-4.6"
    case .moonshot: "kimi-k2.5"
    case .deepSeek: "deepseek-chat"
    case .mistral: "mistral-large-latest"
    case .groq: "llama-3.3-70b-versatile"
    case .gemini: "gemini-flash-latest"
    case .openRouter: "openrouter/auto"
    case .local: "local-model"
    }
  }
}

/// Safe startup fallbacks shared by the model picker and adapters. Account-aware catalogs replace
/// these at runtime for Claude Code, Codex, Otto Harness, Cursor, Grok, Kimi, and OpenCode.
/// Hermes alone resolves model
/// choice through its gateway configuration, while shell sessions have no model.
public enum AgentModelCatalog {
  public static func options(for provider: AgentProvider) -> [AgentModel] {
    switch provider {
    case .claudeCode:
      // Legacy display names for persisted selections. Picker choices come from Claude Code's
      // initialize response, including the current names behind its family aliases.
      [
        AgentModel(id: "fable", displayName: "Fable (latest)"),
        AgentModel(id: "sonnet", displayName: "Sonnet (latest)"),
        AgentModel(id: "opus", displayName: "Opus (latest)"),
        AgentModel(id: "haiku", displayName: "Haiku (latest)"),
        AgentModel(id: "claude-fable-5-1", displayName: "Fable 5.1"),
        AgentModel(id: "claude-fable-5", displayName: "Fable 5"),
        AgentModel(id: "claude-opus-5", displayName: "Opus 5"),
        AgentModel(id: "claude-sonnet-5", displayName: "Sonnet 5"),
        AgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8"),
        AgentModel(id: "claude-opus-4-7", displayName: "Opus 4.7"),
        AgentModel(id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5"),
      ]
    case .codex:
      [
        AgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
        AgentModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
        AgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
        AgentModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        AgentModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
      ]
    case .openAI:
      [
        AgentModel(id: "openai/gpt-5.6", displayName: "OpenAI · GPT-5.6"),
        AgentModel(id: "openai/gpt-5.4-mini", displayName: "OpenAI · GPT-5.4 Mini"),
        AgentModel(
          id: "anthropic/claude-fable-5-1", displayName: "Anthropic · Claude Fable 5.1"),
        AgentModel(id: "anthropic/claude-sonnet-5", displayName: "Anthropic · Claude Sonnet 5"),
        AgentModel(id: "anthropic/claude-opus-5", displayName: "Anthropic · Claude Opus 5"),
        AgentModel(id: "anthropic/claude-fable-5", displayName: "Anthropic · Claude Fable 5"),
        AgentModel(id: "anthropic/claude-opus-4-8", displayName: "Anthropic · Claude Opus 4.8"),
        AgentModel(
          id: "anthropic/claude-haiku-4-5-20251001",
          displayName: "Anthropic · Claude Haiku 4.5"),
        AgentModel(id: "xai/grok-4.6", displayName: "xAI · Grok 4.6"),
        AgentModel(id: "xai/grok-4.5", displayName: "xAI · Grok 4.5"),
        AgentModel(id: "moonshot/kimi-k2.5", displayName: "Moonshot · Kimi K2.5"),
        AgentModel(id: "deepseek/deepseek-chat", displayName: "DeepSeek · DeepSeek Chat"),
        AgentModel(id: "deepseek/deepseek-reasoner", displayName: "DeepSeek · DeepSeek Reasoner"),
        AgentModel(id: "mistral/mistral-large-latest", displayName: "Mistral · Mistral Large"),
        AgentModel(id: "groq/llama-3.3-70b-versatile", displayName: "Groq · Llama 3.3 70B"),
        AgentModel(id: "gemini/gemini-flash-latest", displayName: "Google Gemini · Flash"),
        AgentModel(id: "openrouter/openrouter/auto", displayName: "OpenRouter · Auto"),
      ]
    case .cursor:
      // Cursor's real catalog is account-specific and read from `cursor-agent models`; this is
      // only the fallback for when the CLI cannot be asked.
      [
        AgentModel(id: "auto", displayName: "Auto"),
        AgentModel(id: "composer-2.5", displayName: "Composer 2.5"),
      ]
    case .grok:
      // Grok's live catalog is read from `grok models`; this is the fallback when the CLI
      // cannot be asked. IDs are the slugs `--model` accepts.
      [
        AgentModel(id: "grok-4.6", displayName: "Grok 4.6"),
        AgentModel(id: "grok-4.5", displayName: "Grok 4.5"),
      ]
    case .kimi:
      [
        AgentModel(id: "kimi-code/k3", displayName: "K3"),
        AgentModel(
          id: "kimi-code/kimi-for-coding-highspeed", displayName: "Kimi for Coding · High Speed"),
        AgentModel(id: "kimi-code/kimi-for-coding", displayName: "Kimi for Coding"),
      ]
    case .hermes, .openCode, .pi, .shell:
      // Pi's catalog is whatever providers the user has signed into, read live from
      // `pi --list-models`; there is no safe static list.
      []
    }
  }

  /// Reasoning-effort levels for providers that support one, ordered fastest to smartest.
  /// Claude Code and Grok take `--effort`; Codex takes `model_reasoning_effort`.
  public static func effortLevels(for provider: AgentProvider, modelID: String? = nil) -> [String] {
    switch provider {
    case .claudeCode, .grok: ["low", "medium", "high", "xhigh", "max"]
    // Pi takes `--thinking` and clamps it to what the chosen model supports.
    case .pi: ["minimal", "low", "medium", "high", "xhigh", "max"]
    case .codex:
      modelID == "gpt-5.6-luna"
        ? ["low", "medium", "high", "xhigh", "max"]
        : ["low", "medium", "high", "xhigh", "max", "ultra"]
    case .openAI:
      switch OttoHarnessModelSelection.resolve(modelID).provider {
      case .openAI: ["none", "low", "medium", "high", "xhigh", "max"]
      case .anthropic: ["low", "medium", "high", "max"]
      case .xAI: ["low", "medium", "high", "xhigh"]
      case .moonshot, .deepSeek, .mistral, .groq, .gemini, .openRouter, .local: []
      }
    default: []
    }
  }

  public static func displayName(forModelID id: String, provider: AgentProvider) -> String {
    options(for: provider).first { $0.id == id }?.displayName ?? id
  }

  /// Filters a catalog for the picker's search box. Every word must appear in the model's name or
  /// id, so "opus anthropic" or "gpt 6" narrows a several-hundred-model OpenCode list the way a
  /// person expects; separators are ignored so "gpt6" still finds "gpt-6".
  public static func matching(_ models: [AgentModel], query: String) -> [AgentModel] {
    func fold(_ text: String) -> String {
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
    func squash(_ text: String) -> String { String(text.filter { $0.isLetter || $0.isNumber }) }
    let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return models }
    return models.filter { model in
      let haystack = fold("\(model.displayName) \(model.id)")
      let squashed = squash(haystack)
      return words.allSatisfy { haystack.contains($0) || squashed.contains(squash($0)) }
    }
  }

  /// Whether Otto may set this provider's model at launch. Derived from the catalog rather than
  /// listed by hand, so a provider that gains models becomes switchable in the picker and the
  /// `agent.set_model` tool at the same time. An empty catalog means the CLI owns the choice.
  public static func supportsModelSelection(for provider: AgentProvider) -> Bool {
    switch provider {
    case .hermes, .shell: false
    default: true
    }
  }
}

public enum AgentPermissionMode: String, Codable, CaseIterable, Sendable {
  case readOnly
  case workspaceWrite
  case unrestricted
}

public struct AgentLaunchRequest: Sendable, Equatable {
  public var workspacePath: String
  public var prompt: String?
  public var model: String?
  public var effort: String?
  public var executionStrategy: AgentExecutionStrategy
  public var permissionMode: AgentPermissionMode
  public var resumeSessionID: String?
  /// Path to the otto-mcp bridge. When set, adapters register it with the provider CLI so the
  /// agent can drive the canvas (browser nodes, documents, layout) through Otto tools.
  public var ottoMCPExecutable: String?
  /// OTTO_* control values the bridge needs to reach back into the app. Provider CLIs launch
  /// MCP servers with a scrubbed environment (Codex whitelists a handful of variables), so the
  /// adapter must pass these explicitly in the MCP server configuration — inheriting the parent
  /// process environment is not enough.
  public var controlEnvironment: [String: String]
  /// Otto tool names (e.g. `smtp.send`) whose definitions require confirmation. Otto shows its
  /// own permission card before any of these runs, so adapters may pre-approve exactly these at
  /// the provider level to avoid a second prompt. Never the whole server: tools such as
  /// `terminal.open` carry no Otto card and must stay behind the provider's own approval.
  public var ottoSelfConfirmingTools: [String]
  /// Otto's own workspace, where Otto stages chat attachments. Nil, or equal to `workspacePath`,
  /// when the run starts there; otherwise the run starts in a project's source folder.
  public var ottoWorkspacePath: String?
  /// The bot's current authored role and operating instructions. This travels separately from
  /// memory so adapters can place it in their strongest supported instruction channel on every
  /// turn, including resumed sessions.
  public var profileInstructions: String?
  /// Rendered memory bootstrap packet for this run — charter, compact context, and memory
  /// rules. Adapters deliver it through their provider's instruction mechanism; the supervisor
  /// also writes it to `.otto/bootstrap/` so every provider and the user can inspect it.
  public var memoryBootstrap: String?
  /// Provider account this run bills to. Resolved by the supervisor immediately before launch
  /// when the caller leaves it nil; nil after resolution means the Mac's existing login.
  public var account: AgentAccountLaunch?

  public init(
    workspacePath: String,
    prompt: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    executionStrategy: AgentExecutionStrategy = .direct,
    permissionMode: AgentPermissionMode = .workspaceWrite,
    resumeSessionID: String? = nil,
    ottoMCPExecutable: String? = nil,
    controlEnvironment: [String: String] = [:],
    ottoSelfConfirmingTools: [String] = [],
    ottoWorkspacePath: String? = nil,
    profileInstructions: String? = nil,
    memoryBootstrap: String? = nil
  ) {
    self.workspacePath = workspacePath
    self.prompt = prompt
    self.model = model
    self.effort = effort
    self.executionStrategy = executionStrategy
    self.permissionMode = permissionMode
    self.resumeSessionID = resumeSessionID
    self.ottoMCPExecutable = ottoMCPExecutable
    self.controlEnvironment = controlEnvironment
    self.ottoSelfConfirmingTools = ottoSelfConfirmingTools
    self.ottoWorkspacePath = ottoWorkspacePath
    self.profileInstructions = profileInstructions
    self.memoryBootstrap = memoryBootstrap
  }
}

/// Credentials for one launch on a named provider account. `environment` is applied to the
/// provider process last, so it overrides adapter defaults (e.g. relocating `CODEX_HOME`).
/// It can carry API keys: never log or persist it.
public struct AgentAccountLaunch: Sendable, Equatable {
  public var accountID: UUID
  public var accountName: String
  public var environment: [String: String]
  public var inheritedEnvironmentPrefixesToRemove: [String]
  /// Otto Harness backend keys keyed by base credential key (e.g. `openai.api-key`).
  public var harnessCredentials: [String: String]

  public init(
    accountID: UUID, accountName: String, environment: [String: String] = [:],
    harnessCredentials: [String: String] = [:],
    inheritedEnvironmentPrefixesToRemove: [String] = []
  ) {
    self.accountID = accountID
    self.accountName = accountName
    self.environment = environment
    self.inheritedEnvironmentPrefixesToRemove = inheritedEnvironmentPrefixesToRemove
    self.harnessCredentials = harnessCredentials
  }
}

/// One run's bootstrap as produced by the memory layer: the exact rendered text plus the stable
/// hash persisted with the run so a reviewer can prove what the worker knew at launch.
public struct AgentBootstrapPacket: Sendable, Equatable {
  public let text: String
  public let hash: String

  public init(text: String, hash: String) {
    self.text = text
    self.hash = hash
  }
}

/// Runtime control-plane wiring the app hands to the supervisor once its control socket is up.
/// Spawned providers receive these values through their child environment, which is also how
/// the otto-mcp bridge they launch authenticates back to the app.
public struct AgentControlPlane: Sendable {
  public var socketPath: String
  public var mcpExecutable: String?
  public var workspaceID: UUID
  /// Registry names of the tools Otto confirms with its own card; copied into every launch
  /// request as `AgentLaunchRequest.ottoSelfConfirmingTools`.
  public var selfConfirmingTools: [String]
  /// Otto's own workspace. Otto keeps its per-run files (bootstrap copies, chat images) here even
  /// when a session starts in a project's source folder, so it never writes into that folder.
  public var workspacePath: String?
  private let tokenProvider: @Sendable (UUID, UUID?) async -> String

  public init(
    socketPath: String, token: String, mcpExecutable: String?, workspaceID: UUID,
    selfConfirmingTools: [String] = [], workspacePath: String? = nil
  ) {
    self.socketPath = socketPath
    self.mcpExecutable = mcpExecutable
    self.workspaceID = workspaceID
    self.selfConfirmingTools = selfConfirmingTools
    self.workspacePath = workspacePath
    self.tokenProvider = { _, _ in token }
  }

  public init(
    socketPath: String,
    mcpExecutable: String?,
    workspaceID: UUID,
    selfConfirmingTools: [String] = [],
    workspacePath: String? = nil,
    tokenProvider: @escaping @Sendable (UUID, UUID?) async -> String
  ) {
    self.socketPath = socketPath
    self.mcpExecutable = mcpExecutable
    self.workspaceID = workspaceID
    self.selfConfirmingTools = selfConfirmingTools
    self.workspacePath = workspacePath
    self.tokenProvider = tokenProvider
  }

  public func token(nodeID: UUID, canvasID: UUID?) async -> String {
    await tokenProvider(nodeID, canvasID)
  }
}

public struct AgentContext: Sendable, Equatable {
  public var nodeID: UUID
  public var workspaceID: UUID
  public var controlSocket: String
  public var controlToken: String
  public var mcpExecutable: String

  public init(
    nodeID: UUID,
    workspaceID: UUID,
    controlSocket: String,
    controlToken: String,
    mcpExecutable: String
  ) {
    self.nodeID = nodeID
    self.workspaceID = workspaceID
    self.controlSocket = controlSocket
    self.controlToken = controlToken
    self.mcpExecutable = mcpExecutable
  }
}

public protocol AgentAdapter: Sendable {
  var provider: AgentProvider { get }
  func detectInstallation() async -> InstallationStatus
  func availableModels() async -> [AgentModel]
  /// The catalog as seen by one provider account (its relocated home or API key). Adapters whose
  /// catalog does not depend on the account keep the default, which ignores the environment.
  func availableModels(environment: [String: String]) async -> [AgentModel]
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec
  func environment(for context: AgentContext) -> [String: String]
}

extension AgentAdapter {
  public func availableModels(environment: [String: String]) async -> [AgentModel] {
    await availableModels()
  }
}

public enum ExecutableLocator {
  public static func candidates(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory(),
    preferredPaths: [String] = []
  ) -> [String] {
    let pathDirectories = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    let launchServicesFallbacks = [
      "\(homeDirectory)/.local/bin",
      "\(homeDirectory)/.npm-global/bin",
      "\(homeDirectory)/.bun/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
    ]
    let discoveredPaths = (pathDirectories + launchServicesFallbacks).map {
      URL(fileURLWithPath: $0).appending(path: name).path
    }
    var visited = Set<String>()
    return (preferredPaths + discoveredPaths).compactMap { path in
      let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
      guard visited.insert(standardized).inserted,
        FileManager.default.isExecutableFile(atPath: standardized)
      else { return nil }
      return standardized
    }
  }

  public static func find(
    _ name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory(),
    preferredPaths: [String] = []
  )
    -> String?
  {
    candidates(
      name,
      environment: environment,
      homeDirectory: homeDirectory,
      preferredPaths: preferredPaths
    ).first
  }

  public static func firstWorking(
    candidates: [String],
    versionArguments: [String] = ["--version"],
    environment: [String: String] = [:]
  ) async -> (path: String, version: String)? {
    for path in candidates {
      if let version = await version(
        executable: path, arguments: versionArguments, environment: environment)
      {
        return (path, version)
      }
    }
    return nil
  }

  /// Reads a provider list command's stdout without a terminal attached, with a bound on how long
  /// it may take.
  ///
  /// This deliberately does not reuse the PTY path below. A CLI that detects a terminal may page,
  /// colorize, or render an interactive view instead of printing and exiting — `cursor-agent
  /// models` hangs forever under a PTY — so list commands get pipes, a null stdin, and a watchdog.
  public static func captureOutput(
    executable: String,
    arguments: [String],
    environment: [String: String] = [:],
    timeout: Duration = .seconds(20),
    inheritedEnvironmentPrefixesToRemove: [String] = []
  ) async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty || !inheritedEnvironmentPrefixesToRemove.isEmpty {
          process.environment = ProcessLaunchSpec(
            executable: executable, environment: environment,
            inheritedEnvironmentPrefixesToRemove: inheritedEnvironmentPrefixesToRemove,
            workingDirectory: "/"
          ).resolvedEnvironment(inheriting: ProcessInfo.processInfo.environment)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // A CLI that decides to prompt reads EOF immediately instead of waiting on a human.
        process.standardInput = FileHandle.nullDevice
        do {
          try process.run()
        } catch {
          continuation.resume(returning: nil)
          return
        }
        let watchdog = Task {
          try? await Task.sleep(for: timeout)
          if process.isRunning { process.terminate() }
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
          continuation.resume(returning: nil)
          return
        }
        let text = String(decoding: data, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(returning: text.isEmpty ? nil : text)
      }
    }
  }

  /// `environment` is applied on top of the inherited one; a CLI that is really a `node` script
  /// behind an `env` shebang needs its interpreter's directory on PATH before it can report a
  /// version at all.
  public static func version(
    executable: String,
    arguments: [String] = ["--version"],
    environment: [String: String] = [:]
  ) async -> String? {
    do {
      let process = try PTYProcess.spawn(
        ProcessLaunchSpec(
          executable: executable,
          arguments: arguments,
          environment: environment,
          workingDirectory: FileManager.default.currentDirectoryPath
        ))
      var data = Data()
      for await chunk in process.output { data.append(chunk) }
      var exitCode: Int32?
      for await code in process.exit { exitCode = code }
      guard exitCode == 0 else { return nil }
      let version = String(decoding: data, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return version.isEmpty ? nil : version
    } catch {
      return nil
    }
  }
}

extension AgentAdapter {
  public func environment(for context: AgentContext) -> [String: String] {
    [
      "OTTO_CONTROL_SOCKET": context.controlSocket,
      "OTTO_CONTROL_TOKEN": context.controlToken,
      "OTTO_NODE_ID": context.nodeID.uuidString,
      "OTTO_WORKSPACE_ID": context.workspaceID.uuidString,
      "OTTO_MCP": context.mcpExecutable,
    ]
  }
}
