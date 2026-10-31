import Foundation
import OttoControl
import OttoModels
import OttoTools

public struct MCPRequest: Codable, Sendable, Equatable {
  public var jsonrpc: String
  public var id: JSONValue?
  public var method: String
  public var params: JSONValue?

  public init(jsonrpc: String = "2.0", id: JSONValue?, method: String, params: JSONValue? = nil) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.method = method
    self.params = params
  }
}

public struct MCPError: Codable, Sendable, Equatable {
  public var code: Int
  public var message: String
}

public struct MCPResponse: Codable, Sendable, Equatable {
  public var jsonrpc = "2.0"
  public var id: JSONValue?
  public var result: JSONValue?
  public var error: MCPError?
}

public struct MCPBridge: Sendable {
  private let client: ControlClient
  private let isCancelled: @Sendable () -> Bool
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(client: ControlClient, isCancelled: @escaping @Sendable () -> Bool = { false }) {
    self.client = client
    self.isCancelled = isCancelled
    encoder.outputFormatting = [.sortedKeys]
  }

  public func handle(line: String) -> String {
    do {
      let request = try decoder.decode(MCPRequest.self, from: Data(line.utf8))
      let response = try handle(request)
      return String(decoding: try encoder.encode(response), as: UTF8.self)
    } catch {
      let response = MCPResponse(
        id: nil,
        result: nil,
        error: MCPError(code: -32_700, message: error.localizedDescription)
      )
      return String(decoding: (try? encoder.encode(response)) ?? Data(), as: UTF8.self)
    }
  }

  public func handle(_ request: MCPRequest) throws -> MCPResponse {
    switch request.method {
    case "initialize":
      return MCPResponse(
        id: request.id,
        result: .object([
          "protocolVersion": .string("2025-03-26"),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object([
            "name": .string("otto-mcp"),
            "version": .string("0.1.0"),
          ]),
        ]),
        error: nil
      )
    case "notifications/initialized":
      return MCPResponse(id: request.id, result: .object([:]), error: nil)
    case "tools/list":
      let definitions = try client.listTools()
      let tools = definitions.map { definition in
        var tool: [String: JSONValue] = [
          "name": .string(definition.name),
          "description": .string(definition.description),
          "inputSchema": definition.inputSchema,
        ]
        if Self.alwaysLoadedTools.contains(definition.name) {
          tool["_meta"] = .object(["anthropic/alwaysLoad": .bool(true)])
        }
        return JSONValue.object(tool)
      }
      return MCPResponse(
        id: request.id,
        result: .object(["tools": .array(tools)]),
        error: nil
      )
    case "tools/call":
      guard let requestedName = request.params?["name"]?.stringValue else {
        return methodError(request.id, code: -32_602, message: "tools/call requires params.name")
      }
      // Claude namespaces MCP tools and sanitizes characters outside [A-Za-z0-9_-] to
      // underscores; depending on client version the invoke may carry the sanitized form
      // ("agent_send_prompt") instead of the registry name ("agent.send_prompt"). Accept both.
      let name = canonicalToolName(requestedName)
      let arguments = request.params?["arguments"] ?? .object([:])
      // Permission approvals and user questions block on a human decision in the Otto app, so
      // these calls get an hour-scale read timeout instead of the control plane's ten-second
      // default.
      let timeoutMilliseconds = Self.toolTimeoutMilliseconds(name: name, arguments: arguments)
      do {
        let output = try callWithConfirmation(
          name: name,
          arguments: arguments,
          timeoutMilliseconds: timeoutMilliseconds
        )
        let text = String(decoding: try encoder.encode(output), as: UTF8.self)
        return MCPResponse(
          id: request.id,
          result: .object([
            "content": .array([
              .object(["type": .string("text"), "text": .string(text)])
            ]),
            "isError": .bool(false),
          ]),
          error: nil
        )
      } catch {
        return MCPResponse(
          id: request.id,
          result: .object([
            "content": .array([
              .object(["type": .string("text"), "text": .string(error.localizedDescription)])
            ]),
            "isError": .bool(true),
          ]),
          error: nil
        )
      }
    default:
      return methodError(request.id, code: -32_601, message: "Method not found: \(request.method)")
    }
  }

  /// Claude Code defers MCP tool schemas behind its ToolSearch step. That keeps the ~140 Otto
  /// tools out of every prompt, but costs a visible extra round trip before routine browser
  /// work. These core tools load up front (a few thousand cached tokens); the rest stay deferred.
  static let alwaysLoadedTools: Set<String> = [
    "node.list", "agent.ask_user", "docs.create",
    "browser.open", "browser.open_tab", "browser.navigate", "browser.get_state",
    "browser.inspect", "browser.click", "browser.type", "browser.scroll",
    "browser.screenshot", "browser.get_selection",
  ]

  private func canonicalToolName(_ name: String) -> String {
    guard !name.contains(".") else { return name }
    guard let definitions = try? client.listTools() else { return name }
    if definitions.contains(where: { $0.name == name }) { return name }
    return definitions.first { Self.mcpSanitized($0.name) == name }?.name ?? name
  }

  /// Keep transport deadlines longer than the bounded operation they carry.
  static func toolTimeoutMilliseconds(name: String, arguments: JSONValue) -> Int32? {
    switch name {
    case AgentPermissionPrompt.toolName: return AgentPermissionPrompt.responseTimeoutMilliseconds
    case AgentUserChoicePrompt.toolName: return AgentUserChoicePrompt.responseTimeoutMilliseconds
    case "browser.account" where ["request_login", "click"].contains(arguments["action"]?.stringValue ?? ""):
      return AgentPermissionPrompt.responseTimeoutMilliseconds
    case "event.wait", "terminal.wait":
      return Int32(min((arguments["timeoutMilliseconds"]?.numberValue ?? 30_000) + 5_000, 35_000))
    case "nylas.accounts", "nylas.search", "nylas.read", "nylas.folders", "nylas.drafts",
      "nylas.sort", "nylas.draft", "nylas.send", "nylas.delete_permanently":
      // One private credential load, bounded grant pagination, and provider read/write/readback
      // can exceed ten seconds. Do not abandon an in-flight write and invite duplicate retries.
      // Each provider request has a 30-second resource deadline; this covers the bounded chain.
      return 600_000
    default: return nil
    }
  }

  /// Some Otto tools can only classify whether an action is consequential after inspecting the
  /// live target (for example, a browser click on a Send button). Surface that late-bound approval
  /// through the same in-chat permission card as provider-level requests, then replay the exact
  /// input once with the control plane's confirmation bit set.
  private func callWithConfirmation(
    name: String,
    arguments: JSONValue,
    timeoutMilliseconds: Int32?
  ) throws -> JSONValue {
    guard !isCancelled() else {
      throw ControlProtocolError.invalidRequest("Request cancelled; the action was not performed.")
    }
    do {
      return try client.call(
        name,
        arguments: arguments,
        timeoutMilliseconds: timeoutMilliseconds
      )
    } catch ControlProtocolError.remote(let failure)
      where failure.code == "tool_error"
      && failure.message == ToolRegistryError.confirmationRequired(name).localizedDescription
    {
      guard !isCancelled() else {
        throw ControlProtocolError.invalidRequest(
          "Request cancelled; the action was not performed.")
      }
      let approval = try client.call(
        AgentPermissionPrompt.toolName,
        arguments: .object([
          "tool_name": .string(name),
          "input": arguments,
        ]),
        timeoutMilliseconds: name == "browser.click"
          ? AgentPermissionPrompt.browserResponseTimeoutMilliseconds
          : AgentPermissionPrompt.responseTimeoutMilliseconds
      )
      guard approval["behavior"]?.stringValue == "allow" else {
        throw ControlProtocolError.remote(
          ControlFailure(
            code: "confirmation_denied",
            message: approval["message"]?.stringValue ?? failure.message))
      }
      guard !isCancelled() else {
        throw ControlProtocolError.invalidRequest(
          "Request cancelled; the action was not performed.")
      }
      return try client.call(
        name,
        arguments: arguments,
        confirmed: true,
        timeoutMilliseconds: timeoutMilliseconds
      )
    }
  }

  static func mcpSanitized(_ name: String) -> String {
    String(
      name.map { character in
        character.isLetter || character.isNumber || character == "_" || character == "-"
          ? character : "_"
      })
  }

  private func methodError(_ id: JSONValue?, code: Int, message: String) -> MCPResponse {
    MCPResponse(id: id, result: nil, error: MCPError(code: code, message: message))
  }
}
