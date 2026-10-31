import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Terminal tools for interactive steps")
struct TerminalWaitingToolTests {
  @Test(
    "An agent's terminal belongs to its chat and terminal.wait returns when it needs the person")
  func agentTerminalWaitsForPerson() async throws {
    let canvas = OttoCanvas(name: "Interactive terminal")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    await supervisor.setTerminalInputQuietInterval(.milliseconds(250))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(in: registry, store: store, supervisor: supervisor)
    let agent = await store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
      .affectedNodeIDs[0]
    let context = ToolContext(
      actorID: "interactive-terminal", scopes: [.canvasRead, .canvasWrite, .terminalControl],
      confirmed: true,
      source: .agent, sourceNodeID: agent, sourceCanvasID: canvas.id)
    defer { Task { await supervisor.stopAll() } }

    let run = try await registry.call(
      name: "terminal.run",
      input: try JSONValue.encode(
        TerminalRunInput(
          command: "printf 'Press Enter to continue '; read -r _; echo finished", x: 0, y: 0,
          shell: "/bin/sh")),
      context: context
    ).decode(TerminalOutput.self)
    #expect(run.title == "Command")
    #expect(run.whereToFindIt?.contains("work panel on the right") == true)

    let node = try #require(
      await store.snapshot.canvases.flatMap(\.nodes).first { $0.id == run.terminalID })
    #expect(node.parentAgentID == agent)
    #expect(node.displayName == run.title)
    #expect(node.subtitle.hasPrefix("printf 'Press Enter"))
    // The agent's terminal must not take the conversation's selection.
    #expect(await store.activeCanvas.selectedNodeID != run.terminalID)

    let waiting = try await registry.call(
      name: "terminal.wait",
      input: try JSONValue.encode(
        TerminalWaitInput(terminalID: run.terminalID, timeoutMilliseconds: 10_000)),
      context: context
    ).decode(TerminalOutput.self)
    #expect(waiting.state == .waitingUser)
    #expect(waiting.waitingForUser == true)
    #expect(waiting.prompt == "Press Enter to continue")
    #expect(waiting.exitCode == nil)

    try await supervisor.sendBytes(agentID: run.terminalID, data: Data("\r".utf8))
    let done = try await registry.call(
      name: "terminal.wait",
      input: try JSONValue.encode(
        TerminalWaitInput(terminalID: run.terminalID, timeoutMilliseconds: 10_000)),
      context: context
    ).decode(TerminalOutput.self)
    #expect(done.state == .done)
    #expect(done.waitingForUser == nil)
    #expect(done.boundedOutput.contains("finished"))
  }

  @Test("The tool descriptions tell agents where the person finds the terminal")
  func descriptionsPointAtChat() {
    #expect(TerminalRunTool.definition.description.contains("work panel on the right"))
    #expect(TerminalRunTool.definition.description.contains("waitingForUser"))
    #expect(TerminalOpenTool.definition.description.contains("work panel on"))
    #expect(!TerminalOpenTool.definition.description.contains("sidebar"))
    #expect(!TerminalRunTool.definition.description.contains("sidebar"))
    #expect(TerminalWaitTool.definition.description.contains("waitingForUser"))
  }
}
