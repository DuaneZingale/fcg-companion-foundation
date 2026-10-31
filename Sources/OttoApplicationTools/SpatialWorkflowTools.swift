import Foundation
import OttoBrowser
import OttoCore
import OttoDocuments
import OttoModels
import OttoTools

public typealias ProjectDocumentPathResolver =
  @Sendable (String, ToolContext, Bool) async throws -> String

public struct BrowserOpenInput: Codable, Sendable {
  public var url: String
  public var x: Double
  public var y: Double
  public init(url: String, x: Double, y: Double) {
    self.url = url
    self.x = x
    self.y = y
  }
}

public struct BrowserNavigateInput: Codable, Sendable {
  public var nodeID: UUID
  public var url: String
  public init(nodeID: UUID, url: String) {
    self.nodeID = nodeID
    self.url = url
  }
}

public struct BrowserOpenTabInput: Codable, Sendable {
  public var url: String
  public var nodeID: UUID?
  public init(url: String, nodeID: UUID? = nil) {
    self.url = url
    self.nodeID = nodeID
  }
}

/// A browser surface opened by a canvas agent. The application UI uses this ephemeral signal to
/// present the browser inside that agent's Chat work panel instead of losing the relationship and
/// leaving the new browser as an unexplained resource preview.
public struct AgentBrowserOpenRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let agentID: UUID
  public let browserID: UUID

  public init(id: UUID = UUID(), agentID: UUID, browserID: UUID) {
    self.id = id
    self.agentID = agentID
    self.browserID = browserID
  }
}

public typealias AgentBrowserOpenHandler = @Sendable (AgentBrowserOpenRequest) async -> Void

public struct BrowserSelectionInput: Codable, Sendable {
  public var nodeID: UUID?
  public init(nodeID: UUID? = nil) { self.nodeID = nodeID }
}

public struct BrowserNodeInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct BrowserElementInput: Codable, Sendable {
  public var nodeID: UUID
  public var pageRevision: String?
  public var elementID: String

  public init(nodeID: UUID, pageRevision: String? = nil, elementID: String) {
    self.nodeID = nodeID
    self.pageRevision = pageRevision
    self.elementID = elementID
  }
}

public struct BrowserTypeInput: Codable, Sendable {
  public var nodeID: UUID
  public var pageRevision: String?
  public var elementID: String
  public var text: String

  public init(nodeID: UUID, pageRevision: String? = nil, elementID: String, text: String) {
    self.nodeID = nodeID
    self.pageRevision = pageRevision
    self.elementID = elementID
    self.text = text
  }
}

public struct BrowserScrollInput: Codable, Sendable {
  public var nodeID: UUID
  public var pageRevision: String?
  public var deltaX: Double
  public var deltaY: Double

  public init(nodeID: UUID, pageRevision: String? = nil, deltaX: Double = 0, deltaY: Double) {
    self.nodeID = nodeID
    self.pageRevision = pageRevision
    self.deltaX = deltaX
    self.deltaY = deltaY
  }
}

public struct BrowserScreenshotOutput: Codable, Sendable, Equatable {
  public var nodeID: UUID
  public var relativePath: String
  public var mimeType: String
  public var pixelWidth: Int
  public var pixelHeight: Int
  public var byteCount: Int
}

/// Serializes browser topology changes across browser.open and browser.open_tab. ToolRegistry is
/// actor-isolated but reentrant while a tool call awaits, so the store mutation and runtime
/// synchronization need an explicit gate to remain one transaction.
public actor BrowserOpenGate {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  public func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  public func release() {
    if waiters.isEmpty {
      isLocked = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

public struct BrowserOpenTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.open",
    description:
      "Opens a URL in the Otto browser. Agent, voice, and automation calls reuse the selected or latest browser as a new tab; the first call creates the browser node.",
    inputSchema: .objectSchema(
      properties: [
        "url": .stringSchema(description: "HTTP or HTTPS URL to open"),
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
      ],
      required: ["url", "x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  private let gate: BrowserOpenGate
  private let agentOpenHandler: AgentBrowserOpenHandler?
  public init(
    store: CanvasStore,
    runtime: BrowserRuntime,
    gate: BrowserOpenGate,
    agentOpenHandler: AgentBrowserOpenHandler? = nil
  ) {
    self.store = store
    self.runtime = runtime
    self.gate = gate
    self.agentOpenHandler = agentOpenHandler
  }

  public func call(_ input: BrowserOpenInput, context: ToolContext) async throws -> NodeCreateOutput
  {
    let url = try validatedURL(input.url)
    await gate.acquire()
    do {
      let reusesBrowser =
        context.source == .agent || context.source == .voice || context.source == .automation
      let point = WorldPoint(x: input.x, y: input.y)
      let target: BrowserStoreOpenTarget
      if context.source == .agent, let agentID = context.sourceNodeID {
        target = .ownedByAgent(agentID, fallbackAt: point)
      } else if reusesBrowser {
        target = .selectedOrLatest(fallbackAt: point)
      } else {
        target = .newNode(at: point)
      }
      let mutation = try await openBrowserInStore(
        url: url, target: target, store: store, context: context)
      _ = await runtime.synchronize(
        nodeID: mutation.node.id,
        session: mutation.session,
        navigatingTabID: mutation.openedTab.id
      )
      if context.source == .agent, let agentID = context.sourceNodeID {
        await agentOpenHandler?(
          AgentBrowserOpenRequest(agentID: agentID, browserID: mutation.node.id))
      }
      await gate.release()
      return NodeCreateOutput(node: mutation.node, message: mutation.message)
    } catch {
      await gate.release()
      throw error
    }
  }
}

public struct BrowserOpenTabTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.open_tab",
    description:
      "Opens a URL in a new tab inside an existing Otto browser. If nodeID is omitted, uses the selected browser or the latest browser node.",
    inputSchema: .objectSchema(
      properties: [
        "url": .stringSchema(description: "HTTP or HTTPS URL to open"),
        "nodeID": .stringSchema(description: "Optional browser node UUID"),
      ],
      required: ["url"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  private let gate: BrowserOpenGate
  private let agentOpenHandler: AgentBrowserOpenHandler?
  public init(
    store: CanvasStore,
    runtime: BrowserRuntime,
    gate: BrowserOpenGate,
    agentOpenHandler: AgentBrowserOpenHandler? = nil
  ) {
    self.store = store
    self.runtime = runtime
    self.gate = gate
    self.agentOpenHandler = agentOpenHandler
  }

  public func call(_ input: BrowserOpenTabInput, context: ToolContext) async throws
    -> BrowserRuntimeState
  {
    let url = try validatedURL(input.url)
    await gate.acquire()
    do {
      let mutation = try await openBrowserInStore(
        url: url,
        target: .existing(input.nodeID),
        store: store,
        context: context
      )
      let state = await runtime.synchronize(
        nodeID: mutation.node.id,
        session: mutation.session,
        navigatingTabID: mutation.openedTab.id
      )
      if context.source == .agent, let agentID = context.sourceNodeID {
        await agentOpenHandler?(
          AgentBrowserOpenRequest(agentID: agentID, browserID: mutation.node.id))
      }
      await gate.release()
      return state
    } catch {
      await gate.release()
      throw error
    }
  }
}

public struct BrowserGetSelectionTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.get_selection",
    description:
      "Returns the webpage element selected by the user, including accessible identity, CSS selector, bounds, computed styles, URL and route. Use this before changing a user-selected UI element.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(
          description: "Optional browser node UUID; omit to use the current browser")
      ],
      required: []
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }

  public func call(_ input: BrowserSelectionInput, context: ToolContext) async throws
    -> BrowserElementSelection
  {
    let nodeID = try await preferredBrowserNodeID(input.nodeID, store: store, context: context)
    try await ensureBrowserSession(nodeID: nodeID, store: store, runtime: runtime, context: context)
    guard let selection = await runtime.state(nodeID: nodeID)?.selectedElement else {
      throw ToolRegistryError.invalidInput(
        "No element is selected; ask the user to choose Select element in the browser")
    }
    return selection
  }
}

public struct BrowserNavigateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.navigate",
    description: "Navigates an existing browser node to an HTTP or HTTPS URL.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable browser node UUID"),
        "url": .stringSchema(description: "HTTP or HTTPS destination URL"),
      ],
      required: ["nodeID", "url"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }

  public func call(_ input: BrowserNavigateInput, context: ToolContext) async throws
    -> MutationOutput
  {
    let url = try validatedURL(input.url)
    try await ensureBrowserSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    try await runtime.navigate(nodeID: input.nodeID, url: url)
    let receipt = try await store.dispatch(
      .setNodeContent(id: input.nodeID, content: .browser(url: url)),
      context: context
    )
    return MutationOutput(message: receipt.message, affectedNodeIDs: receipt.affectedNodeIDs)
  }
}

public struct BrowserRefreshTool: OttoTool {
  public static let definition = browserCommandDefinition(
    name: "browser.refresh", description: "Refreshes an existing browser node.")
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: BrowserNodeInput, context: ToolContext) async throws
    -> BrowserRuntimeState
  {
    try await ensureBrowserSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.refresh(nodeID: input.nodeID)
  }
}

public struct BrowserBackTool: OttoTool {
  public static let definition = browserCommandDefinition(
    name: "browser.back", description: "Navigates an existing browser node backward.")
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: BrowserNodeInput, context: ToolContext) async throws
    -> BrowserRuntimeState
  {
    try await ensureBrowserSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.back(nodeID: input.nodeID)
  }
}

public struct BrowserForwardTool: OttoTool {
  public static let definition = browserCommandDefinition(
    name: "browser.forward", description: "Navigates an existing browser node forward.")
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: BrowserNodeInput, context: ToolContext) async throws
    -> BrowserRuntimeState
  {
    try await ensureBrowserSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.forward(nodeID: input.nodeID)
  }
}

public struct BrowserGetStateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.get_state",
    description: "Returns current URL, title, loading, and history state for a browser node.",
    inputSchema: browserNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: BrowserNodeInput, context: ToolContext) async throws
    -> BrowserRuntimeState
  {
    try await ensureBrowserSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    guard let state = await runtime.state(nodeID: input.nodeID) else {
      throw BrowserRuntimeError.unknownNode(input.nodeID)
    }
    return state
  }
}

public struct BrowserInspectTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.inspect",
    description:
      "Returns interactive elements across the full page (visible ones first, including open shadow roots) in a browser or GTM Grid node with stable IDs and accessible names. Interaction tools automatically use the latest inspection, scroll off-screen elements into view, and accept either an ID or an exact name.",
    inputSchema: interactiveWebNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime

  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }

  public func call(_ input: BrowserNodeInput, context: ToolContext) async throws
    -> BrowserPageSnapshot
  {
    try await ensureInteractiveWebSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.inspectPage(nodeID: input.nodeID)
  }
}

public struct BrowserClickTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.click",
    description:
      "Clicks an element returned by browser.inspect in a browser or GTM Grid node. Routine actions run directly; consequential external actions require confirmation unless the agent session is in bypass mode.",
    inputSchema: interactiveWebElementSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead, .canvasWrite],
    riskLevel: .consequential
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime

  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }

  public func call(_ input: BrowserElementInput, context: ToolContext) async throws
    -> BrowserInteractionResult
  {
    try await ensureInteractiveWebSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    let resolved = try await runtime.resolveElement(
      nodeID: input.nodeID, reference: input.elementID)
    let request = BrowserInteractionRequest(
      revision: resolved.pageRevision, kind: .click, elementID: resolved.elementID)
    try await requireBrowserClickConfirmation(
      nodeID: input.nodeID,
      request: request,
      toolName: Self.definition.name,
      runtime: runtime,
      context: context
    )
    return try await runtime.interact(nodeID: input.nodeID, request: request)
  }
}

public struct BrowserTypeTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.type",
    description:
      "Replaces the contents of a text field returned by browser.inspect in a browser or GTM Grid node. This edits the field but does not submit it; use browser.click for a Send or Submit button.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable browser or GTM Grid node UUID"),
        "pageRevision": .stringSchema(
          description: "Optional pageRevision returned by browser.inspect"),
        "elementID": .stringSchema(
          description: "Element ID or exact accessible name returned by browser.inspect"),
        "text": .stringSchema(description: "Text to enter"),
      ],
      required: ["nodeID", "elementID", "text"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead, .canvasWrite],
    riskLevel: .consequential
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime

  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }

  public func call(_ input: BrowserTypeInput, context: ToolContext) async throws
    -> BrowserInteractionResult
  {
    try await ensureInteractiveWebSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    let resolved = try await runtime.resolveElement(
      nodeID: input.nodeID, reference: input.elementID)
    return try await runtime.interact(
      nodeID: input.nodeID,
      request: BrowserInteractionRequest(
        revision: resolved.pageRevision,
        kind: .type,
        elementID: resolved.elementID,
        text: input.text
      ))
  }
}

public struct BrowserScrollTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.scroll",
    description: "Scrolls an inspected browser or GTM Grid page by viewport pixels.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable browser or GTM Grid node UUID"),
        "pageRevision": .stringSchema(
          description: "Optional pageRevision returned by browser.inspect"),
        "deltaX": .numberSchema(description: "Horizontal scroll amount in CSS pixels"),
        "deltaY": .numberSchema(description: "Vertical scroll amount in CSS pixels"),
      ],
      required: ["nodeID", "deltaX", "deltaY"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead, .canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime

  public init(store: CanvasStore, runtime: BrowserRuntime) {
    self.store = store
    self.runtime = runtime
  }

  public func call(_ input: BrowserScrollInput, context: ToolContext) async throws
    -> BrowserInteractionResult
  {
    try await ensureInteractiveWebSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    let pageRevision = try await runtime.latestPageRevision(nodeID: input.nodeID)
    return try await runtime.interact(
      nodeID: input.nodeID,
      request: BrowserInteractionRequest(
        revision: pageRevision,
        kind: .scroll,
        deltaX: input.deltaX,
        deltaY: input.deltaY
      ))
  }
}

public struct BrowserScreenshotTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.screenshot",
    description:
      "Captures a visible browser or GTM Grid node to a generated workspace-confined PNG file.",
    inputSchema: interactiveWebNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead, .canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let runtime: BrowserRuntime
  private let workspaceURL: URL

  public init(store: CanvasStore, runtime: BrowserRuntime, workspacePath: String) {
    self.store = store
    self.runtime = runtime
    self.workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
  }

  public func call(_ input: BrowserNodeInput, context: ToolContext) async throws
    -> BrowserScreenshotOutput
  {
    try await ensureInteractiveWebSession(
      nodeID: input.nodeID, store: store, runtime: runtime, context: context)
    let capture = try await runtime.capture(nodeID: input.nodeID)
    let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    guard capture.pngData.starts(with: pngSignature), capture.pixelWidth > 0,
      capture.pixelHeight > 0
    else {
      throw ToolRegistryError.invalidInput("Browser returned an empty screenshot")
    }
    let relativePath =
      ".otto/captures/\(input.nodeID.uuidString.lowercased())-\(captureTimestamp()).png"
    let destination = workspaceURL.appending(path: relativePath).standardizedFileURL
    let workspacePrefix =
      workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
    guard destination.path.hasPrefix(workspacePrefix) else {
      throw ToolRegistryError.invalidInput("Screenshot destination escaped the workspace")
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try capture.pngData.write(to: destination, options: .atomic)
    return BrowserScreenshotOutput(
      nodeID: input.nodeID,
      relativePath: relativePath,
      mimeType: "image/png",
      pixelWidth: capture.pixelWidth,
      pixelHeight: capture.pixelHeight,
      byteCount: capture.pngData.count
    )
  }

  private func captureTimestamp() -> String {
    String(Int(Date().timeIntervalSince1970 * 1_000))
  }
}

public struct BrowserOpenExternalInput: Codable, Sendable {
  public var url: String
  public init(url: String) { self.url = url }
}

public typealias ExternalURLOpener = @Sendable (URL) async -> Bool

public struct BrowserOpenExternalTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.open_external",
    description:
      "Opens an HTTP or HTTPS URL in the user's default system browser, outside Otto. Use only when the user explicitly asks for their own or default browser; otherwise prefer browser.open.",
    inputSchema: .objectSchema(
      properties: [
        "url": .stringSchema(description: "HTTP or HTTPS URL to hand to the system browser")
      ],
      required: ["url"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .consequential
  )
  private let opener: ExternalURLOpener
  public init(opener: @escaping ExternalURLOpener) {
    self.opener = opener
  }

  public func call(_ input: BrowserOpenExternalInput, context: ToolContext) async throws
    -> MutationOutput
  {
    let validated = try validatedURL(input.url)
    guard let url = URL(string: validated) else {
      throw ToolRegistryError.invalidInput("Browser URL could not be parsed")
    }
    guard await opener(url) else {
      throw ToolRegistryError.invalidInput("The system browser declined to open the URL")
    }
    return MutationOutput(
      message: "Opened \(validated) in the default browser", affectedNodeIDs: [])
  }
}

public struct DocumentCreateInput: Codable, Sendable {
  public var relativePath: String
  public var text: String
  public var x: Double
  public var y: Double
  public init(relativePath: String, text: String, x: Double, y: Double) {
    self.relativePath = relativePath
    self.text = text
    self.x = x
    self.y = y
  }
}

public struct DocumentOpenInput: Codable, Sendable {
  public var relativePath: String
  public var x: Double
  public var y: Double
  public init(relativePath: String, x: Double, y: Double) {
    self.relativePath = relativePath
    self.x = x
    self.y = y
  }
}

public struct DocumentReplaceInput: Codable, Sendable {
  public var nodeID: UUID
  public var relativePath: String
  public var text: String
  public init(nodeID: UUID, relativePath: String, text: String) {
    self.nodeID = nodeID
    self.relativePath = relativePath
    self.text = text
  }
}

public struct DocumentNodeInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct DocumentAppendInput: Codable, Sendable {
  public var nodeID: UUID
  public var text: String
  public init(nodeID: UUID, text: String) {
    self.nodeID = nodeID
    self.text = text
  }
}

public struct DocumentChecklistInput: Codable, Sendable {
  public var nodeID: UUID
  public var itemNumber: Int
  public var completed: Bool
  public var replacementText: String?

  public init(
    nodeID: UUID,
    itemNumber: Int,
    completed: Bool,
    replacementText: String? = nil
  ) {
    self.nodeID = nodeID
    self.itemNumber = itemNumber
    self.completed = completed
    self.replacementText = replacementText
  }
}

public struct DocumentReadOutput: Codable, Sendable, Equatable {
  public var nodeID: UUID
  public var relativePath: String
  public var text: String
}

public struct DocumentCreateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "document.create",
    description:
      "Creates a workspace Markdown file (legacy). For user-facing documents use docs.create, which saves to Documents. Return the file link from the result in Chat.",
    inputSchema: .objectSchema(
      properties: [
        "relativePath": .stringSchema(description: "Workspace-relative Markdown file path"),
        "text": .stringSchema(description: "Initial Markdown content"),
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
      ],
      required: ["relativePath", "text", "x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let projectPath: ProjectDocumentPathResolver?
  public init(
    store: CanvasStore, documents: WorkspaceDocumentStore,
    projectPath: ProjectDocumentPathResolver? = nil
  ) {
    self.projectPath = projectPath
    self.store = store
    self.documents = documents
  }

  public func call(_ input: DocumentCreateInput, context: ToolContext) async throws
    -> NodeCreateOutput
  {
    let path = try await projectPath?(input.relativePath, context, true) ?? input.relativePath
    try await documents.replace(relativePath: path, text: input.text)
    let receipt = try await store.dispatch(
      .createNode(kind: .markdown, at: WorldPoint(x: input.x, y: input.y)),
      context: context
    )
    guard let id = receipt.affectedNodeIDs.first else {
      throw ToolRegistryError.invalidInput("Document creation failed")
    }
    _ = try await store.dispatch(
      .setNodeContent(
        id: id,
        content: .markdown(relativePath: path, text: input.text)
      ),
      context: context
    )
    guard let node = try await store.canvas(for: context).nodes.first(where: { $0.id == id }) else {
      throw ToolRegistryError.invalidInput("Document creation produced no node")
    }
    let fileURL = URL(fileURLWithPath: documents.rootPath).appendingPathComponent(path)
    return NodeCreateOutput(
      node: node,
      message:
        "Markdown file available. Return this link in Chat: [Open document](<\(fileURL.path)>). "
        + "This is a workspace file, not a Documents entry; do not direct the user to Canvas.")
  }
}

public struct DocumentOpenTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "document.open",
    description:
      "Loads an existing workspace Markdown file (legacy). This does not open a user-visible Documents entry. Return the file link from the result in Chat.",
    inputSchema: .objectSchema(
      properties: [
        "relativePath": .stringSchema(description: "Existing workspace-relative Markdown path"),
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
      ],
      required: ["relativePath", "x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead, .canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let projectPath: ProjectDocumentPathResolver?
  public init(
    store: CanvasStore, documents: WorkspaceDocumentStore,
    projectPath: ProjectDocumentPathResolver? = nil
  ) {
    self.projectPath = projectPath
    self.store = store
    self.documents = documents
  }
  public func call(_ input: DocumentOpenInput, context: ToolContext) async throws
    -> NodeCreateOutput
  {
    let path = try await projectPath?(input.relativePath, context, false) ?? input.relativePath
    _ = try await projectPath?(path, context, false)
    let text = try await documents.read(relativePath: path)
    let receipt = try await store.dispatch(
      .createNode(kind: .markdown, at: WorldPoint(x: input.x, y: input.y)),
      context: context
    )
    guard let id = receipt.affectedNodeIDs.first else {
      throw ToolRegistryError.invalidInput("Document node creation failed")
    }
    _ = try await store.dispatch(
      .setNodeContent(
        id: id,
        content: .markdown(relativePath: path, text: text)),
      context: context
    )
    guard let node = try await store.canvas(for: context).nodes.first(where: { $0.id == id }) else {
      throw ToolRegistryError.invalidInput("Document node creation produced no node")
    }
    let fileURL = URL(fileURLWithPath: documents.rootPath).appendingPathComponent(path)
    return NodeCreateOutput(
      node: node,
      message:
        "Markdown file available. Return this link in Chat: [Open document](<\(fileURL.path)>). "
        + "This is a workspace file, not a Documents entry; do not direct the user to Canvas.")
  }
}

public struct DocumentReplaceTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "document.replace",
    description: "Atomically replaces a workspace Markdown file and its visible node content.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable document node UUID"),
        "relativePath": .stringSchema(description: "Workspace-relative Markdown path"),
        "text": .stringSchema(description: "Complete replacement Markdown content"),
      ],
      required: ["nodeID", "relativePath", "text"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .consequential
  )
  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let projectPath: ProjectDocumentPathResolver?
  public init(
    store: CanvasStore, documents: WorkspaceDocumentStore,
    projectPath: ProjectDocumentPathResolver? = nil
  ) {
    self.projectPath = projectPath
    self.store = store
    self.documents = documents
  }

  public func call(_ input: DocumentReplaceInput, context: ToolContext) async throws
    -> MutationOutput
  {
    let path = try await projectPath?(input.relativePath, context, false) ?? input.relativePath
    try await documents.replace(relativePath: path, text: input.text)
    _ = try await store.requiredNode(input.nodeID, context: context)
    let receipt = try await store.dispatch(
      .setNodeContent(
        id: input.nodeID,
        content: .markdown(relativePath: path, text: input.text)
      ),
      context: context
    )
    return MutationOutput(message: receipt.message, affectedNodeIDs: receipt.affectedNodeIDs)
  }
}

public struct DocumentReadTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "document.read",
    description: "Reads a file-backed Markdown node from its workspace-confined path.",
    inputSchema: documentNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let projectPath: ProjectDocumentPathResolver?
  public init(
    store: CanvasStore, documents: WorkspaceDocumentStore,
    projectPath: ProjectDocumentPathResolver? = nil
  ) {
    self.projectPath = projectPath
    self.store = store
    self.documents = documents
  }

  public func call(_ input: DocumentNodeInput, context: ToolContext) async throws
    -> DocumentReadOutput
  {
    let path = try await documentPath(nodeID: input.nodeID, store: store, context: context)
    _ = try await projectPath?(path, context, false)
    let text = try await documents.read(relativePath: path)
    return DocumentReadOutput(nodeID: input.nodeID, relativePath: path, text: text)
  }
}

public struct DocumentAppendTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "document.append",
    description: "Atomically appends text to a file-backed Markdown node.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable document node UUID"),
        "text": .stringSchema(description: "Markdown text to append"),
      ],
      required: ["nodeID", "text"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .consequential
  )
  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let projectPath: ProjectDocumentPathResolver?
  public init(
    store: CanvasStore, documents: WorkspaceDocumentStore,
    projectPath: ProjectDocumentPathResolver? = nil
  ) {
    self.projectPath = projectPath
    self.store = store
    self.documents = documents
  }

  public func call(_ input: DocumentAppendInput, context: ToolContext) async throws
    -> MutationOutput
  {
    let path = try await documentPath(nodeID: input.nodeID, store: store, context: context)
    _ = try await projectPath?(path, context, false)
    let updated = try await documents.append(relativePath: path, text: input.text)
    let receipt = try await store.dispatch(
      .setNodeContent(
        id: input.nodeID,
        content: .markdown(relativePath: path, text: updated)
      ),
      context: context
    )
    return MutationOutput(message: receipt.message, affectedNodeIDs: receipt.affectedNodeIDs)
  }
}

public struct DocumentUpdateChecklistItemTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "document.update_checklist_item",
    description: "Updates a one-based Markdown checklist item in a file-backed document node.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable document node UUID"),
        "itemNumber": .integerSchema(description: "One-based checklist item number"),
        "completed": .booleanSchema(description: "Whether the item is complete"),
        "replacementText": .stringSchema(description: "Optional replacement item text"),
      ],
      required: ["nodeID", "itemNumber", "completed"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .consequential
  )
  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let projectPath: ProjectDocumentPathResolver?
  public init(
    store: CanvasStore, documents: WorkspaceDocumentStore,
    projectPath: ProjectDocumentPathResolver? = nil
  ) {
    self.projectPath = projectPath
    self.store = store
    self.documents = documents
  }

  public func call(_ input: DocumentChecklistInput, context: ToolContext) async throws
    -> MutationOutput
  {
    guard input.itemNumber > 0 else {
      throw ToolRegistryError.invalidInput("Checklist item numbers begin at one")
    }
    let path = try await documentPath(nodeID: input.nodeID, store: store, context: context)
    _ = try await projectPath?(path, context, false)
    let current = try await documents.read(relativePath: path)
    let updated = try updateChecklist(current, input: input)
    try await documents.replace(relativePath: path, text: updated)
    let receipt = try await store.dispatch(
      .setNodeContent(
        id: input.nodeID,
        content: .markdown(relativePath: path, text: updated)
      ),
      context: context
    )
    return MutationOutput(message: receipt.message, affectedNodeIDs: receipt.affectedNodeIDs)
  }
}

public struct WorkspaceSurfaceSetInput: Codable, Sendable {
  public var surface: WorkspaceSurface
  public init(surface: WorkspaceSurface) { self.surface = surface }

  private enum CodingKeys: String, CodingKey { case surface }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decode(String.self, forKey: .surface)
    guard let surface = WorkspaceSurface(rawValue: raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: .surface,
        in: container,
        debugDescription: "Unknown workspace surface: \(raw)"
      )
    }
    self.surface = surface
  }
}

public struct ThemeSetInput: Codable, Sendable {
  public var themeID: String
  public init(themeID: String) { self.themeID = themeID }
}

public struct ThemeListInput: Codable, Sendable { public init() {} }

public struct ThemeListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "theme.list",
    description: "Lists installed versioned Otto themes.",
    inputSchema: .objectSchema(),
    outputSchema: .object(["type": .string("array")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  public init() {}
  public func call(_ input: ThemeListInput, context: ToolContext) async throws
    -> [OttoThemeDefinition]
  {
    OttoThemeCatalog.all
  }
}

public struct WorkspaceSurfaceSetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "surface.set",
    description: "Opens the Chat workspace.",
    inputSchema: .objectSchema(
      properties: [
        "surface": .stringSchema(description: "Workspace surface: chat")
      ],
      required: ["surface"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: WorkspaceSurfaceSetInput, context: ToolContext) async throws
    -> MutationOutput
  {
    let receipt = await store.setWorkspaceSurface(input.surface)
    return MutationOutput(message: receipt.message, affectedNodeIDs: [])
  }
}

public struct ThemeSetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "theme.set",
    description: "Applies an installed original Otto theme by ID.",
    inputSchema: .objectSchema(
      properties: ["themeID": .stringSchema(description: "Installed Otto theme ID")],
      required: ["themeID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: ThemeSetInput, context: ToolContext) async throws -> MutationOutput {
    guard let canonical = OttoThemeCatalog.canonicalID(input.themeID) else {
      throw ToolRegistryError.invalidInput("Unknown theme: \(input.themeID)")
    }
    let receipt = try await store.dispatch(.setTheme(canonical), context: context)
    return MutationOutput(message: receipt.message, affectedNodeIDs: [])
  }
}

private func validatedURL(_ value: String) throws -> String {
  guard value.utf8.count <= 8_192,
    !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  else {
    throw ToolRegistryError.invalidInput("Browser URL is too long or contains control characters")
  }
  let normalized = value.contains("://") ? value : "http://\(value)"
  guard let components = URLComponents(string: normalized),
    ["http", "https"].contains(components.scheme?.lowercased()),
    components.host != nil,
    components.user == nil,
    components.password == nil,
    let url = components.url
  else {
    throw ToolRegistryError.invalidInput(
      "Browser URLs must use HTTP or HTTPS, include a host, and omit credentials")
  }
  return url.absoluteString
}

private func browserCommandDefinition(name: String, description: String) -> ToolDefinition {
  ToolDefinition(
    name: name,
    description: description,
    inputSchema: browserNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
}

private func browserNodeSchema() -> JSONValue {
  .objectSchema(
    properties: ["nodeID": .stringSchema(description: "Stable browser node UUID")],
    required: ["nodeID"]
  )
}

private func browserElementSchema() -> JSONValue {
  .objectSchema(
    properties: [
      "nodeID": .stringSchema(description: "Stable browser node UUID"),
      "pageRevision": .stringSchema(
        description: "Optional pageRevision returned by browser.inspect"),
      "elementID": .stringSchema(
        description: "Element ID or exact accessible name returned by browser.inspect"),
    ],
    required: ["nodeID", "elementID"]
  )
}

private func interactiveWebNodeSchema() -> JSONValue {
  .objectSchema(
    properties: [
      "nodeID": .stringSchema(description: "Stable browser or GTM Grid node UUID")
    ],
    required: ["nodeID"]
  )
}

private func interactiveWebElementSchema() -> JSONValue {
  .objectSchema(
    properties: [
      "nodeID": .stringSchema(description: "Stable browser or GTM Grid node UUID"),
      "pageRevision": .stringSchema(
        description: "Optional pageRevision returned by browser.inspect"),
      "elementID": .stringSchema(
        description: "Element ID or exact accessible name returned by browser.inspect"),
    ],
    required: ["nodeID", "elementID"]
  )
}

private func documentNodeSchema() -> JSONValue {
  .objectSchema(
    properties: ["nodeID": .stringSchema(description: "Stable document node UUID")],
    required: ["nodeID"]
  )
}

private enum BrowserStoreOpenTarget: Sendable {
  case newNode(at: WorldPoint)
  case ownedByAgent(UUID, fallbackAt: WorldPoint)
  case selectedOrLatest(fallbackAt: WorldPoint)
  case existing(UUID?)
}

private struct BrowserStoreOpenMutation: Sendable {
  var node: OttoNode
  var session: BrowserSession
  var openedTab: BrowserTab
  var message: String
}

/// Resolves/creates the browser and commits its persisted tab topology without suspending. This
/// runs as one MainActor critical section, so no caller can observe a half-created browser or
/// overwrite another tool call's session snapshot.
@MainActor
private func openBrowserInStore(
  url: String,
  target: BrowserStoreOpenTarget,
  store: CanvasStore,
  context: ToolContext
) throws -> BrowserStoreOpenMutation {
  let canvas = try store.canvas(for: context)
  let previousSelection = canvas.selectedNodeID
  let shouldFocus = context.interactionPrivileges.contains(.focusUserInterface)

  func preferredBrowserID() -> UUID? {
    if let selected = canvas.selectedNodeID,
      canvas.nodes.contains(where: { $0.id == selected && $0.kind == .browser })
    {
      return selected
    }
    return canvas.nodes.last(where: { $0.kind == .browser })?.id
  }

  func createBrowser(at point: WorldPoint) throws -> (id: UUID, message: String) {
    let receipt = try store.dispatch(.createNode(kind: .browser, at: point), context: context)
    guard let id = receipt.affectedNodeIDs.first else {
      throw ToolRegistryError.invalidInput("Browser creation failed")
    }
    return (id, receipt.message)
  }

  let nodeID: UUID
  let created: Bool
  let creationMessage: String?
  switch target {
  case .newNode(let point):
    let creation = try createBrowser(at: point)
    nodeID = creation.id
    created = true
    creationMessage = creation.message
  case .ownedByAgent(let agentID, let point):
    if let existing = canvas.nodes.last(where: {
      $0.kind == .browser && $0.browserOwnerAgentID == agentID
    }) {
      nodeID = existing.id
      created = false
      creationMessage = nil
    } else {
      let creation = try createBrowser(at: point)
      nodeID = creation.id
      created = true
      creationMessage = creation.message
      _ = try store.dispatch(.setBrowserOwner(id: nodeID, agentID: agentID), context: context)
    }
  case .selectedOrLatest(let point):
    if let existing = preferredBrowserID() {
      nodeID = existing
      created = false
      creationMessage = nil
    } else {
      let creation = try createBrowser(at: point)
      nodeID = creation.id
      created = true
      creationMessage = creation.message
    }
  case .existing(let requested):
    guard let existing = requested ?? preferredBrowserID() else {
      throw ToolRegistryError.invalidInput(
        "No browser node is open; use browser.open to create the first browser")
    }
    guard canvas.nodes.contains(where: { $0.id == existing && $0.kind == .browser }) else {
      throw ToolRegistryError.invalidInput("Node is not a browser")
    }
    nodeID = existing
    created = false
    creationMessage = nil
  }

  let current = try store.requiredNode(nodeID, context: context)
  guard case .browser(let currentURL) = current.content else {
    throw ToolRegistryError.invalidInput("Node is not a browser")
  }
  var session = current.browserSession ?? BrowserSession(url: currentURL)
  let openedTab: BrowserTab
  if created {
    guard let activeIndex = session.tabs.firstIndex(where: { $0.id == session.activeTabID }) else {
      throw ToolRegistryError.invalidInput("Browser creation produced no active tab")
    }
    session.tabs[activeIndex].url = url
    session.tabs[activeIndex].title = "Loading…"
    openedTab = session.tabs[activeIndex]
  } else {
    openedTab = BrowserTab(title: "Loading…", url: url)
    session.tabs.append(openedTab)
    session.activeTabID = openedTab.id
  }

  _ = try store.dispatch(.setBrowserSession(id: nodeID, session: session), context: context)
  _ = try store.dispatch(
    .setNodeContent(id: nodeID, content: .browser(url: url)), context: context)
  if shouldFocus {
    _ = try store.dispatch(.focusNode(nodeID), context: context)
  } else if created {
    _ = try store.dispatch(.focusNode(previousSelection), context: context)
  }

  guard let node = try store.canvas(for: context).nodes.first(where: { $0.id == nodeID }) else {
    throw ToolRegistryError.invalidInput("Browser open produced no node")
  }
  return BrowserStoreOpenMutation(
    node: node,
    session: session,
    openedTab: openedTab,
    message: creationMessage ?? "Opened a new tab in \(node.displayName)"
  )
}

private func ensureBrowserSession(
  nodeID: UUID,
  store: CanvasStore,
  runtime: BrowserRuntime,
  context: ToolContext
) async throws {
  let node = try await store.requiredNode(nodeID, context: context)
  guard case .browser(let url) = node.content
  else {
    throw ToolRegistryError.invalidInput("Node is not a browser")
  }
  let session = node.browserSession ?? BrowserSession(url: url)
  await runtime.synchronize(nodeID: nodeID, session: session)
}

private func ensureInteractiveWebSession(
  nodeID: UUID,
  store: CanvasStore,
  runtime: BrowserRuntime,
  context: ToolContext
) async throws {
  let node = try await store.requiredNode(nodeID, context: context)
  switch node.content {
  case .browser(let browserURL):
    let session = node.browserSession ?? BrowserSession(url: browserURL)
    await runtime.synchronize(nodeID: nodeID, session: session)
  default:
    throw ToolRegistryError.invalidInput("Node is not a browser")
  }
}

private func preferredBrowserNodeID(
  _ requested: UUID?, store: CanvasStore, context: ToolContext
) async throws -> UUID {
  let canvas = try await store.canvas(for: context)
  if let requested {
    guard canvas.nodes.contains(where: { $0.id == requested && $0.kind == .browser }) else {
      throw ToolRegistryError.invalidInput("Node is not a browser")
    }
    return requested
  }
  if let selected = canvas.selectedNodeID,
    canvas.nodes.contains(where: { $0.id == selected && $0.kind == .browser })
  {
    return selected
  }
  if let browser = canvas.nodes.last(where: { $0.kind == .browser }) { return browser.id }
  throw ToolRegistryError.invalidInput(
    "No browser node is open; use browser.open to create the first browser")
}

private func requireBrowserClickConfirmation(
  nodeID: UUID,
  request: BrowserInteractionRequest,
  toolName: String,
  runtime: BrowserRuntime,
  context: ToolContext
) async throws {
  if context.confirmed { return }
  if let value = await runtime.state(nodeID: nodeID)?.url,
    let url = URL(string: value),
    let host = url.host?.lowercased(),
    ["localhost", "127.0.0.1", "::1"].contains(host)
  {
    return
  }
  let assessment = try await runtime.assessInteraction(nodeID: nodeID, request: request)
  if assessment.requiresConfirmation {
    throw ToolRegistryError.confirmationRequired(toolName)
  }
}

private func documentPath(
  nodeID: UUID,
  store: CanvasStore,
  context: ToolContext
) async throws -> String {
  let node = try await store.requiredNode(nodeID, context: context)
  guard case .markdown(let path?, _) = node.content
  else {
    throw ToolRegistryError.invalidInput("Node is not a file-backed Markdown document")
  }
  return path
}

private func updateChecklist(_ text: String, input: DocumentChecklistInput) throws -> String {
  var lines = text.components(separatedBy: "\n")
  let checklistPattern = #"^\s*[-*]\s+\[[ xX]\]\s+"#
  let indices = lines.indices.filter {
    lines[$0].range(of: checklistPattern, options: .regularExpression) != nil
  }
  guard input.itemNumber <= indices.count else {
    throw ToolRegistryError.invalidInput(
      "Checklist item \(input.itemNumber) was not found; document has \(indices.count) items")
  }
  let lineIndex = indices[input.itemNumber - 1]
  let markerPattern = #"\[[ xX]\]"#
  guard let marker = lines[lineIndex].range(of: markerPattern, options: .regularExpression) else {
    throw ToolRegistryError.invalidInput("Checklist item marker was invalid")
  }
  lines[lineIndex].replaceSubrange(marker, with: input.completed ? "[x]" : "[ ]")
  if let replacement = input.replacementText?.trimmingCharacters(in: .whitespacesAndNewlines),
    !replacement.isEmpty,
    let updatedMarker = lines[lineIndex].range(of: markerPattern, options: .regularExpression)
  {
    lines[lineIndex] = String(lines[lineIndex][..<updatedMarker.upperBound]) + " " + replacement
  }
  return lines.joined(separator: "\n")
}
