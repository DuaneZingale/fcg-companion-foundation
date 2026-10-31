import Foundation
import OttoModels
import OttoRuntime
import OttoTools

/// Payload Claude Code sends to its `--permission-prompt-tool`. Extra provider fields such as
/// `permission_suggestions` are accepted and ignored.
public struct AgentPermissionPromptInput: Codable, Sendable {
  public var toolName: String
  public var input: JSONValue?
  public var toolUseID: String?

  enum CodingKeys: String, CodingKey {
    case toolName = "tool_name"
    case input
    case toolUseID = "tool_use_id"
  }

  public init(toolName: String, input: JSONValue? = nil, toolUseID: String? = nil) {
    self.toolName = toolName
    self.input = input
    self.toolUseID = toolUseID
  }
}

/// Claude Code's required response contract: the tool result text must be JSON with `behavior`
/// "allow" (echoing the input as `updatedInput`) or "deny" (with a `message`).
public struct AgentPermissionPromptOutput: Codable, Sendable, Equatable {
  public var behavior: String
  public var updatedInput: JSONValue?
  public var message: String?

  public static func allow(updatedInput: JSONValue) -> Self {
    Self(behavior: "allow", updatedInput: updatedInput, message: nil)
  }

  public static func deny(message: String) -> Self {
    Self(behavior: "deny", updatedInput: nil, message: message)
  }
}

/// The approval tool one-shot provider runs call through the otto-mcp bridge whenever Claude
/// Code needs tool permission. It parks the request on the supervisor, which surfaces the agent
/// as WAITING_PERMISSION until the user answers in the conversation, then relays the decision.
/// Every failure path returns a structured deny rather than throwing, so the provider always
/// receives the JSON contract it expects.
public struct AgentRequestPermissionTool: OttoTool {
  public static let definition = ToolDefinition(
    name: AgentPermissionPrompt.toolName,
    description:
      "Requests the user's permission for a provider tool call and blocks until they approve or deny it in the agent conversation. Called automatically by provider CLIs; agents never need to invoke it directly.",
    inputSchema: .objectSchema(
      properties: [
        "tool_name": .stringSchema(description: "Tool the provider wants to run"),
        "input": .object([
          "type": .string("object"),
          "description": .string("Input the provider wants to pass to the tool"),
        ]),
        "tool_use_id": .stringSchema(description: "Provider identifier for this tool use"),
        "permission_suggestions": .object([
          "type": .string("array"),
          "description": .string("Optional provider permission suggestions; accepted and ignored"),
          "items": .object([:]),
        ]),
      ],
      required: ["tool_name"]
      // Closed schema, like every registered tool. If a future provider adds payload fields the
      // call fails validation and the provider receives an error, which it treats as a denial —
      // extend the properties above rather than opening the schema.
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read,
    providerInternal: true
  )

  private let supervisor: AgentSupervisor
  private let browserConfirmationTimeout: Duration
  private let emailOriginal: EmailApprovalSummary.OriginalLookup?

  public init(
    supervisor: AgentSupervisor,
    browserConfirmationTimeout: Duration = AgentPermissionPrompt.browserConfirmationTimeout,
    emailOriginal: EmailApprovalSummary.OriginalLookup? = nil
  ) {
    self.supervisor = supervisor
    self.browserConfirmationTimeout = browserConfirmationTimeout
    self.emailOriginal = emailOriginal
  }

  public func call(_ input: AgentPermissionPromptInput, context: ToolContext) async throws
    -> AgentPermissionPromptOutput
  {
    guard let agentID = context.sourceNodeID ?? Self.nodeID(fromActorID: context.actorID) else {
      return .deny(message: "Otto could not identify the agent requesting permission")
    }
    var detail = Self.detail(toolName: input.toolName, input: input.input)
    if input.toolName == "nylas.delete_permanently" {
      guard case .object(let object)? = input.input else {
        return .deny(message: "Could not identify the email to delete")
      }
      if let refusal = NylasDeleteApprovalSummary.refusal(input: object) {
        return .deny(message: refusal)
      }
      detail = NylasDeleteApprovalSummary.text(input: object)
    }
    if input.toolName == "terminal.run" {
      guard case .object(let object)? = input.input else {
        return .deny(message: "Otto could not read the terminal command to approve")
      }
      if let refusal = TerminalCommandApprovalSummary.refusal(input: object) {
        return .deny(message: refusal)
      }
      detail = TerminalCommandApprovalSummary.text(input: object)
    }
    if ["terminal.wait", "terminal.read_output"].contains(input.toolName) {
      guard let terminalID = input.input?["terminalID"]?.stringValue,
        UUID(uuidString: terminalID) != nil
      else { return .deny(message: "Otto could not identify the terminal output to approve") }
      detail = "Read output from terminal \(terminalID). This does not start another command."
      if input.toolName == "terminal.wait" {
        let timeout = input.input?["timeoutMilliseconds"]?.numberValue ?? 30_000
        guard timeout.isFinite, (1...30_000).contains(timeout) else {
          return .deny(message: "Terminal wait timeout must be between 1 and 30000 milliseconds")
        }
        detail += "\nWait up to \(Int(timeout)) milliseconds."
      }
    }
    if EmailApprovalSummary.tools.contains(input.toolName) {
      // The card shows the whole message, so one too long to show is refused, not cut short.
      guard case .object(let object)? = input.input else {
        return .deny(message: "Otto could not read the email to approve")
      }
      if let refusal = EmailApprovalSummary.refusal(input: object) {
        return .deny(message: refusal)
      }
      let original = await emailOriginal?(input.toolName, object, context)
      detail =
        EmailApprovalSummary.text(toolName: input.toolName, input: object, original: original)
        ?? detail
    }
    do {
      let approved = try await supervisor.requestPermission(
        agentID: agentID,
        toolName: input.toolName,
        detail: detail,
        timeout: input.toolName == "browser.click" ? browserConfirmationTimeout : nil,
        // Dotted Otto tools are app confirmations; the supervisor also applies tool bypass
        // to browser.click, while account access and other app confirmations stay explicit.
        isProviderPermission: !input.toolName.contains("."),
        detailLimit: input.toolName == "nylas.delete_permanently" ? NylasDeleteApprovalSummary.limit
          : input.toolName == "terminal.run"
          ? TerminalCommandApprovalSummary.limit
          : EmailApprovalSummary.tools.contains(input.toolName) ? EmailApprovalSummary.limit : 240
      )
      if approved {
        return .allow(updatedInput: input.input ?? .object([:]))
      }
      return .deny(message: "The user denied \(input.toolName) in Otto")
    } catch RuntimeError.permissionExpired {
      return .deny(message: RuntimeError.permissionExpired.localizedDescription)
    } catch {
      return .deny(
        message: "Otto could not route this permission request: \(error.localizedDescription)")
    }
  }

  /// Agent control tokens are issued as "otto-agent-<nodeID>" ("muse-agent-<nodeID>" before the
  /// rename); recover the node when the grant did not carry an explicit source node.
  static func nodeID(fromActorID actorID: String) -> UUID? {
    for prefix in ["otto-agent-", "muse-agent-"] where actorID.hasPrefix(prefix) {
      return UUID(uuidString: String(actorID.dropFirst(prefix.count)))
    }
    return nil
  }

  private static func detail(toolName: String, input: JSONValue?) -> String {
    guard case .object(let object)? = input else { return "" }
    if let email = EmailApprovalSummary.text(toolName: toolName, input: object) { return email }
    var bridged: [String: Any] = [:]
    for (key, value) in object {
      if case .string(let string) = value { bridged[key] = string }
    }
    return ClaudeOutputParser.toolDetail(name: toolName, input: bridged)
  }
}

/// A shell command must never be approved from the usual truncated tool preview.
/// Refuse content the card cannot faithfully display instead of hiding an executable suffix.
public enum TerminalCommandApprovalSummary {
  public static let commandLimit = 8_000
  public static let shellLimit = 1_000
  public static let limit = commandLimit + shellLimit + 100

  public static func refusal(input: [String: JSONValue]) -> String? {
    guard let command = input["command"]?.stringValue,
      !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return "A terminal command is required for approval" }
    let shell = input["shell"]?.stringValue ?? "/bin/zsh"
    guard command.count <= commandLimit, shell.count <= shellLimit else {
      return "This terminal command is too long to show in full for approval. Use a shorter command."
    }
    if (command + shell).unicodeScalars.contains(where: {
      ($0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t")
        || $0.properties.generalCategory == .format
    }) {
      return "This terminal command contains control characters Otto cannot show for approval."
    }
    return nil
  }

  public static func text(input: [String: JSONValue]) -> String {
    "Shell: \(input["shell"]?.stringValue ?? "/bin/zsh")\nCommand:\n\(input["command"]?.stringValue ?? "")"
  }
}

/// What the approval card shows before an email goes out: the recipient, the subject and the
/// whole body, so the person approves exactly the message that is sent. A message too long to
/// show in full is refused rather than shown in part.
public enum EmailApprovalSummary {
  public static let tools: Set<String> = ["gmail.send", "gmail.reply", "smtp.send", "nylas.send"]
  /// The longest body the card shows; longer ones are refused.
  public static let bodyLimit = 20_000
  /// Recipient and subject are short in any mail Otto sends; longer ones are refused too.
  static let headerLimit = 1_000
  /// The whole card: the headers, notes about the thread and recipient, and the body.
  public static let limit = bodyLimit + 8 * headerLimit

  /// Who the message being answered came from, as Otto read it from the mail itself.
  public struct Original: Equatable, Sendable {
    public var from: String
    public var replyTo: String?

    public init(from: String, replyTo: String? = nil) {
      self.from = from
      self.replyTo = replyTo
    }
  }

  /// Finds the message a reply answers: Gmail's original for gmail.reply, the triaged mail for
  /// smtp.send with inReplyTo. Nil when there is none or it cannot be read.
  public typealias OriginalLookup =
    @Sendable (String, [String: JSONValue], ToolContext) async -> Original?

  /// Why an email cannot be approved as asked, or nil when the card can show all of it.
  public static func refusal(input: [String: JSONValue]) -> String? {
    let body = input["body"]?.stringValue ?? ""
    if body.count > bodyLimit {
      return
        "This email is \(body.count) characters long; Otto shows the whole message for approval and allows up to \(bodyLimit). Send a shorter message."
    }
    // The card drops terminal control sequences, so a body holding them would read differently
    // from what is sent.
    if body.unicodeScalars.contains(where: {
      ($0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t") || $0.value == 127
    }) {
      return "This email contains control characters Otto cannot show for approval. Remove them."
    }
    for field in ["account", "to", "cc", "bcc", "subject", "replyToMessageID"] {
      let value = input[field]?.stringValue ?? ""
      if value.count > headerLimit { return "This email's \(field) is too long to approve." }
      if value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }) {
        return "This email's \(field) contains characters Otto cannot show faithfully."
      }
    }
    if body.unicodeScalars.contains(where: { $0.properties.generalCategory == .format }) {
      return "This email contains hidden formatting characters Otto cannot show faithfully."
    }
    return nil
  }

  public static func text(
    toolName: String, input: [String: JSONValue], original: Original? = nil
  ) -> String? {
    guard tools.contains(toolName) else { return nil }
    let to = input["to"]?.stringValue ?? "(no recipient)"
    let subject = input["subject"]?.stringValue ?? "(no subject)"
    let body = (input["body"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = ["Send email to \(to)", "Subject: \(subject)"]
    if toolName == "nylas.send" {
      lines.insert("From inbox: \(input["account"]?.stringValue ?? "(missing)")", at: 0)
      lines.append("CC: \(input["cc"]?.stringValue ?? "(none)")")
      lines.append("BCC: \(input["bcc"]?.stringValue ?? "(none)")")
      if let reply = input["replyToMessageID"]?.stringValue { lines.append("Reply to message: \(reply)") }
    }
    if toolName == "gmail.reply" || input["inReplyTo"]?.stringValue != nil {
      lines.append("Reply in the original thread")
    }
    if let original, address(to) != address(original.from) {
      // The original's headers are the sender's to write; keep a long one from crowding the body.
      let sender = String(address(original.from).prefix(200))
      lines.append(
        original.replyTo.map { address($0) == address(to) } == true
          ? "Not the original sender: \(sender) asked for replies to go to \(address(to))"
          : "Not the original sender: the message came from \(sender)")
    }
    lines.append("")
    lines.append(body)
    return lines.joined(separator: "\n")
  }

  /// The bare, lower-cased address from a header such as `Alice <Alice@example.com>`.
  static func address(_ header: String) -> String {
    let trimmed: Substring
    if let start = header.lastIndex(of: "<"), let end = header.lastIndex(of: ">"), start < end {
      trimmed = header[header.index(after: start)..<end]
    } else {
      trimmed = Substring(header)
    }
    return trimmed.trimmingCharacters(in: .whitespaces).lowercased()
  }
}

public enum NylasDeleteApprovalSummary {
  public static let limit = 4_000
  public static func refusal(input: [String: JSONValue]) -> String? {
    for key in ["account", "messageID", "expectedSubject"] {
      guard let value = input[key]?.stringValue, value.count <= 1_000,
        key == "expectedSubject" || !value.isEmpty,
        !value.unicodeScalars.contains(where: {
          $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }) else { return "Cannot display the exact email target for permanent deletion." }
    }
    return nil
  }
  public static func text(input: [String: JSONValue]) -> String {
    "PERMANENTLY DELETE ONE EMAIL — cannot be undone.\nInbox: \(input["account"]?.stringValue ?? "")\nMessage ID: \(input["messageID"]?.stringValue ?? "")\nSubject: \(input["expectedSubject"]?.stringValue ?? "")"
  }
}

public struct AgentAskUserInput: Codable, Sendable {
  public var question: String
  public var choices: [String]?
  public var multiSelect: Bool?

  enum CodingKeys: String, CodingKey {
    case question
    case choices
    case multiSelect = "multi_select"
  }

  public init(question: String, choices: [String]? = nil, multiSelect: Bool? = nil) {
    self.question = question
    self.choices = choices
    self.multiSelect = multiSelect
  }
}

public struct AgentAskUserOutput: Codable, Sendable, Equatable {
  /// The user's answer: one of the offered choices, several joined with ", " when multi-select,
  /// a free-typed reply, or "" when they skipped or the run ended first.
  public var answer: String

  public init(answer: String) {
    self.answer = answer
  }
}

/// The universal in-chat question tool. An agent asks a question with up to a handful of
/// choices; Otto renders them as buttons in the conversation and blocks this call until the
/// user picks one or types their own answer.
public struct AgentAskUserTool: OttoTool {
  public static let definition = ToolDefinition(
    name: AgentUserChoicePrompt.toolName,
    description:
      "Asks the user a question in the agent conversation and blocks until they answer. Provide up to 5 short choices to render as buttons; the user can always type a custom reply instead. Use this when a decision genuinely needs the user, not for confirmations you can infer.",
    inputSchema: .objectSchema(
      properties: [
        "question": .stringSchema(description: "The question to show the user"),
        "choices": .object([
          "type": .string("array"),
          "description": .string("Up to 5 short selectable answers, rendered as buttons"),
          "items": .object(["type": .string("string")]),
        ]),
        "multi_select": .object([
          "type": .string("boolean"),
          "description": .string(
            "Allow selecting several choices; the answer joins them with ', '"),
        ]),
      ],
      required: ["question"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read,
    providerInternal: true
  )

  private let supervisor: AgentSupervisor

  public init(supervisor: AgentSupervisor) {
    self.supervisor = supervisor
  }

  public func call(_ input: AgentAskUserInput, context: ToolContext) async throws
    -> AgentAskUserOutput
  {
    guard
      let agentID = context.sourceNodeID
        ?? AgentRequestPermissionTool.nodeID(fromActorID: context.actorID)
    else {
      throw ToolRegistryError.invalidInput("Otto could not identify the agent asking the question")
    }
    let question = input.question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else {
      throw ToolRegistryError.invalidInput("question must not be empty")
    }
    let answer = try await supervisor.requestChoice(
      agentID: agentID,
      question: question,
      choices: Array((input.choices ?? []).prefix(5)),
      multiSelect: input.multiSelect ?? false
    )
    return AgentAskUserOutput(answer: answer)
  }
}
