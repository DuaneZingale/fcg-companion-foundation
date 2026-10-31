import Foundation

public enum ToolScope: String, Codable, CaseIterable, Sendable {
  case canvasRead = "canvas:read"
  case canvasWrite = "canvas:write"
  case agentRead = "agent:read"
  case agentControl = "agent:control"
  case terminalControl = "terminal:control"
  case globalDestructive = "global:destructive"
}

public enum ToolRiskLevel: String, Codable, Sendable {
  case read
  case reversible
  case consequential
  case destructive
}

public enum ToolInvocationSource: String, Codable, CaseIterable, Sendable {
  case userInterface
  case voice
  case cli
  case agent
  case automation
  case system

  public var defaultInteractionPrivileges: Set<ToolInteractionPrivilege> {
    switch self {
    case .userInterface, .voice, .cli, .system:
      Set(ToolInteractionPrivilege.allCases)
    case .agent, .automation:
      []
    }
  }
}

public enum ToolInteractionPrivilege: String, Codable, CaseIterable, Sendable {
  case switchVisibleCanvas
  case changeViewport
  case focusUserInterface
  case speak
}

/// Tool authors declare external effects explicitly; providers must preserve request IDs on retry.
public enum ToolExternalEffect: String, Codable, Sendable {
  case sendOrPublish, spend, delete, accountChange
}

public enum ToolEffectAdmission: Sendable {
  case execute(UUID)
  case receipt(JSONValue)
}

public struct ToolDefinition: Codable, Equatable, Sendable {
  public var name: String
  public var description: String
  public var inputSchema: JSONValue
  public var outputSchema: JSONValue
  public var requiredScopes: Set<ToolScope>
  public var riskLevel: ToolRiskLevel
  public var requiresConfirmation: Bool
  /// Provider-internal callbacks remain callable through MCP but are not projected into voice or
  /// user-facing command catalogs.
  public var externalEffect: ToolExternalEffect?
  public var providerInternal: Bool?

  public init(
    name: String,
    description: String,
    inputSchema: JSONValue,
    outputSchema: JSONValue,
    requiredScopes: Set<ToolScope>,
    riskLevel: ToolRiskLevel,
    requiresConfirmation: Bool = false,
    providerInternal: Bool = false,
    externalEffect: ToolExternalEffect? = nil
  ) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.requiredScopes = requiredScopes
    self.riskLevel = riskLevel
    self.requiresConfirmation = requiresConfirmation
    self.externalEffect = externalEffect
    self.providerInternal = providerInternal
  }

  public var isProviderInternal: Bool { providerInternal ?? false }

  /// Only declared reads without external effects or a separate confirmation qualify.
  public var allowsUnpromptedRead: Bool {
    riskLevel == .read && !requiresConfirmation && !isProviderInternal && externalEffect == nil
  }
}

public struct ToolContext: Sendable {
  public var actorID: String
  public var scopes: Set<ToolScope>
  public var confirmed: Bool
  public var source: ToolInvocationSource
  public var sourceNodeID: UUID?
  public var sourceCanvasID: UUID?
  public var targetCanvasID: UUID?
  public var interactionPrivileges: Set<ToolInteractionPrivilege>

  public init(
    actorID: String,
    scopes: Set<ToolScope>,
    confirmed: Bool = false,
    source: ToolInvocationSource = .system,
    sourceNodeID: UUID? = nil,
    sourceCanvasID: UUID? = nil,
    targetCanvasID: UUID? = nil,
    interactionPrivileges: Set<ToolInteractionPrivilege>? = nil
  ) {
    self.actorID = actorID
    self.scopes = scopes
    self.confirmed = confirmed
    self.source = source
    self.sourceNodeID = sourceNodeID
    self.sourceCanvasID = sourceCanvasID
    self.targetCanvasID = targetCanvasID
    self.interactionPrivileges =
      interactionPrivileges ?? source.defaultInteractionPrivileges
  }
}

public struct ToolAuditRecord: Identifiable, Sendable, Equatable {
  public let id: UUID
  public let requestID: String
  public let toolName: String
  public let actorID: String
  public let succeeded: Bool
  public let riskLevel: ToolRiskLevel
  public let timestamp: Date
  public let durationMilliseconds: Double?

  public init(
    id: UUID = UUID(),
    requestID: String,
    toolName: String,
    actorID: String,
    succeeded: Bool,
    riskLevel: ToolRiskLevel = .read,
    timestamp: Date = .now,
    durationMilliseconds: Double? = nil
  ) {
    self.id = id
    self.requestID = requestID
    self.toolName = toolName
    self.actorID = actorID
    self.succeeded = succeeded
    self.riskLevel = riskLevel
    self.timestamp = timestamp
    self.durationMilliseconds = durationMilliseconds
  }
}

public protocol ToolAuditSink: Sendable {
  func record(_ record: ToolAuditRecord) async
}

public protocol ExternalEffectCoordinating: Sendable {
  func prepareEffect(
    definition: ToolDefinition, input: JSONValue, context: ToolContext, requestID: String
  ) async throws -> ToolEffectAdmission?
  func completeEffect(id: UUID, output: JSONValue) async throws
  func markEffectUncertain(id: UUID, errorDescription: String) async
}

public struct CompositeToolAuditSink: ToolAuditSink {
  private let sinks: [any ToolAuditSink]

  public init(_ sinks: [any ToolAuditSink]) {
    self.sinks = sinks
  }

  public func record(_ record: ToolAuditRecord) async {
    for sink in sinks { await sink.record(record) }
  }
}

public protocol OttoTool: Sendable {
  associatedtype Input: Codable & Sendable
  associatedtype Output: Codable & Sendable

  static var definition: ToolDefinition { get }
  func call(_ input: Input, context: ToolContext) async throws -> Output
}

public enum ToolRegistryError: Error, LocalizedError, Equatable, Sendable {
  case duplicateTool(String)
  case unknownTool(String)
  case missingScopes(Set<ToolScope>)
  case confirmationRequired(String)
  case invalidInput(String)
  case interactionDenied(ToolInteractionPrivilege)

  public var errorDescription: String? {
    switch self {
    case .duplicateTool(let name): "Tool \(name) is already registered"
    case .unknownTool(let name): "Unknown tool: \(name)"
    case .missingScopes(let scopes):
      "Missing tool scopes: \(scopes.map(\.rawValue).sorted().joined(separator: ", "))"
    case .confirmationRequired(let name): "Tool \(name) requires confirmation"
    case .invalidInput(let message): "Invalid tool input: \(message)"
    case .interactionDenied(let privilege):
      "This request source cannot perform the \(privilege.rawValue) interaction"
    }
  }
}

private struct RegisteredTool: Sendable {
  let definition: ToolDefinition
  let call: @Sendable (JSONValue, ToolContext) async throws -> JSONValue
  let availability: (@Sendable (ToolContext) async -> Bool)?
}

public actor ToolRegistry {
  private var tools: [String: RegisteredTool] = [:]
  private var auditRecords: [ToolAuditRecord] = []
  private let auditSink: (any ToolAuditSink)?
  private var effectCoordinator: (any ExternalEffectCoordinating)?
  // In-memory audit is a diagnostic window, not the durable log (the sink owns durability).
  // Unbounded growth was a session-length memory leak.
  private let auditRecordLimit = 2_000

  public init(
    auditSink: (any ToolAuditSink)? = nil,
    effectCoordinator: (any ExternalEffectCoordinating)? = nil
  ) {
    self.auditSink = auditSink
    self.effectCoordinator = effectCoordinator
  }

  public func setEffectCoordinator(_ coordinator: (any ExternalEffectCoordinating)?) {
    effectCoordinator = coordinator
  }

  public func register<T: OttoTool>(
    _ tool: T, availability: (@Sendable (ToolContext) async -> Bool)? = nil
  ) throws {
    let definition = T.definition
    guard tools[definition.name] == nil else {
      throw ToolRegistryError.duplicateTool(definition.name)
    }
    tools[definition.name] = RegisteredTool(
      definition: definition,
      call: { input, context in
        try ToolInputSchemaValidator.validate(input, against: definition.inputSchema)
        let decoded: T.Input
        do {
          decoded = try input.decode(T.Input.self)
        } catch {
          throw ToolRegistryError.invalidInput(error.localizedDescription)
        }
        return try await JSONValue.encode(tool.call(decoded, context: context))
      }, availability: availability)
  }

  public func definitions() -> [ToolDefinition] {
    tools.values.map(\.definition).sorted { $0.name < $1.name }
  }

  /// Discovery and execution use the same live policy. Cached schemas confer no authority.
  public func definitions(for context: ToolContext) async -> [ToolDefinition] {
    var visible: [ToolDefinition] = []
    for tool in tools.values.sorted(by: { $0.definition.name < $1.definition.name }) {
      guard tool.definition.requiredScopes.isSubset(of: context.scopes) else { continue }
      if let available = tool.availability, !(await available(context)) { continue }
      visible.append(tool.definition)
    }
    return visible
  }

  public func call(
    name: String,
    input: JSONValue,
    context: ToolContext,
    requestID: String = UUID().uuidString
  ) async throws -> JSONValue {
    let started = ContinuousClock.now
    guard let tool = tools[name] else {
      await record(
        requestID: requestID,
        name: name,
        actorID: context.actorID,
        succeeded: false,
        risk: .read,
        durationMilliseconds: milliseconds(since: started)
      )
      throw ToolRegistryError.unknownTool(name)
    }
    if let available = tool.availability, !(await available(context)) {
      await record(
        requestID: requestID, name: name, actorID: context.actorID,
        succeeded: false, risk: tool.definition.riskLevel,
        durationMilliseconds: milliseconds(since: started))
      throw ToolRegistryError.invalidInput("This tool is unavailable to this caller")
    }
    let missingScopes = tool.definition.requiredScopes.subtracting(context.scopes)
    guard missingScopes.isEmpty else {
      await record(
        requestID: requestID,
        name: name,
        actorID: context.actorID,
        succeeded: false,
        risk: tool.definition.riskLevel,
        durationMilliseconds: milliseconds(since: started)
      )
      throw ToolRegistryError.missingScopes(missingScopes)
    }
    if let interactionPrivilege = Self.requiredInteractionPrivilege(for: name),
      !context.interactionPrivileges.contains(interactionPrivilege)
    {
      await record(
        requestID: requestID,
        name: name,
        actorID: context.actorID,
        succeeded: false,
        risk: tool.definition.riskLevel,
        durationMilliseconds: milliseconds(since: started)
      )
      throw ToolRegistryError.interactionDenied(interactionPrivilege)
    }
    guard !tool.definition.requiresConfirmation || context.confirmed else {
      await record(
        requestID: requestID,
        name: name,
        actorID: context.actorID,
        succeeded: false,
        risk: tool.definition.riskLevel,
        durationMilliseconds: milliseconds(since: started)
      )
      throw ToolRegistryError.confirmationRequired(name)
    }

    let admission = try await effectCoordinator?.prepareEffect(
      definition: tool.definition, input: input, context: context, requestID: requestID)
    if case .receipt(let receipt) = admission { return receipt }
    let effectID: UUID? = if case .execute(let id) = admission { id } else { nil }
    do {
      let output = try await tool.call(input, context)
      if let effectID { try await effectCoordinator?.completeEffect(id: effectID, output: output) }
      await record(
        requestID: requestID,
        name: name,
        actorID: context.actorID,
        succeeded: true,
        risk: tool.definition.riskLevel,
        durationMilliseconds: milliseconds(since: started)
      )
      return output
    } catch {
      if let effectID {
        await effectCoordinator?.markEffectUncertain(
          id: effectID, errorDescription: error.localizedDescription)
      }
      await record(
        requestID: requestID,
        name: name,
        actorID: context.actorID,
        succeeded: false,
        risk: tool.definition.riskLevel,
        durationMilliseconds: milliseconds(since: started)
      )
      throw error
    }
  }

  public func auditLog() -> [ToolAuditRecord] {
    auditRecords
  }

  private func record(
    requestID: String,
    name: String,
    actorID: String,
    succeeded: Bool,
    risk: ToolRiskLevel,
    durationMilliseconds: Double
  ) async {
    let record = ToolAuditRecord(
      requestID: requestID,
      toolName: name,
      actorID: actorID,
      succeeded: succeeded,
      riskLevel: risk,
      durationMilliseconds: durationMilliseconds
    )
    auditRecords.append(record)
    if auditRecords.count > auditRecordLimit {
      auditRecords.removeFirst(auditRecords.count - auditRecordLimit)
    }
    await auditSink?.record(record)
  }

  private func milliseconds(since started: ContinuousClock.Instant) -> Double {
    let components = started.duration(to: .now).components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds)
      / 1_000_000_000_000_000
  }

  private static func requiredInteractionPrivilege(
    for toolName: String
  ) -> ToolInteractionPrivilege? {
    switch toolName {
    case "canvas.create", "canvas.switch":
      .switchVisibleCanvas
    case "node.focus", "node.expand", "layout.stage":
      .focusUserInterface
    case "voice.speak", "speech.speak":
      .speak
    default:
      nil
    }
  }
}
