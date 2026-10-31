import Foundation
import OttoApplicationTools
import OttoTools
import Testing

@Suite("Unprompted scoped knowledge reads")
struct KnowledgeReadTests {
  @Test("Reads return inline with bound identity; shell syntax remains ordinary JSON text")
  func readWithoutConfirmation() async throws {
    let profile = UUID()
    let configuration = KnowledgeBridgeConfiguration(executable: "/private/helper",
      actorsByProfileID: [profile.uuidString.lowercased(): "FENWICK"])
    let query = "Wryx; $(touch /tmp/should-never-run)"
    let tool = KnowledgeReadTool(configuration: configuration, profileID: { _ in profile },
      runner: { executable, arguments in
        #expect(executable == "/private/helper")
        #expect(arguments.count == 3)
        #expect(arguments[0] == "FENWICK")
        #expect(arguments[1] == "search")
        let values = try? JSONDecoder().decode([String: String].self, from: Data(arguments[2].utf8))
        #expect(values == ["collection": "roster", "query": query])
        return "{\"observedAt\":\"fixture-time\",\"source\":\"fixture\",\"rows\":[]}"
      })
    let registry = ToolRegistry()
    try await registry.register(tool)
    let result = try await registry.call(name: "knowledge.read", input: .object([
      "action": .string("search"), "collection": .string("roster"), "query": .string(query)]),
      context: ToolContext(actorID: "agent", scopes: [.canvasRead], confirmed: false, source: .agent))
    #expect(result["observedAt"] == .string("fixture-time"))
    #expect(KnowledgeReadTool.definition.allowsUnpromptedRead)
  }

  @Test("Write actions, surplus arguments, unknown callers and missing scopes fail before execution")
  func closedReadBoundary() async throws {
    let profile = UUID()
    let configuration = KnowledgeBridgeConfiguration(executable: "/private/helper",
      actorsByProfileID: [profile.uuidString.lowercased(): "FCG"])
    let registry = ToolRegistry()
    try await registry.register(KnowledgeReadTool(configuration: configuration, profileID: { _ in nil },
      runner: { _, _ in Issue.record("Rejected read reached process execution"); return "{}" }))
    let context = ToolContext(actorID: "agent", scopes: [.canvasRead], source: .agent)
    for input in [
      .object(["action": .string("write")]),
      .object(["action": .string("neon_set_greeting")]),
      .object(["action": .string("identity"), "actor": .string("FCG")]),
      .object(["action": .string("identity"), "query": .string("extra")]),
      .object(["action": .string("lore_read"), "path": .string("../private.md")]),
      .object(["action": .string("identity")]),
    ] as [JSONValue] {
      await #expect(throws: (any Error).self) {
        try await registry.call(name: "knowledge.read", input: input, context: context)
      }
    }
    await #expect(throws: (any Error).self) {
      try await registry.call(name: "knowledge.read", input: .object(["action": .string("identity")]),
        context: ToolContext(actorID: "unscoped", scopes: []))
    }
    #expect(throws: (any Error).self) { try configuration.actor(profileID: UUID()) }
    #expect(try configuration.actor(profileID: profile) == "FCG")
  }

  @Test("Unavailable or malformed reads are failures, never empty successes")
  func failedRead() async throws {
    let profile = UUID()
    for output in [nil, "not-json", "[]", "{\"error\":\"unavailable\"}"] as [String?] {
      let tool = KnowledgeReadTool(configuration: .init(executable: "/helper",
        actorsByProfileID: [profile.uuidString.lowercased(): "FCG"]),
        profileID: { _ in profile }, runner: { _, _ in output })
      await #expect(throws: (any Error).self) {
        try await tool.call(.init(action: "identity"),
          context: ToolContext(actorID: "agent", scopes: [.canvasRead]))
      }
    }
  }

  @Test("Read grants never include confirmed actions, external effects or provider callbacks")
  func readEligibility() {
    var definition = KnowledgeReadTool.definition
    definition.requiresConfirmation = true
    #expect(!definition.allowsUnpromptedRead)
    definition.requiresConfirmation = false
    definition.externalEffect = .sendOrPublish
    #expect(!definition.allowsUnpromptedRead)
    definition.externalEffect = nil
    definition.providerInternal = true
    #expect(!definition.allowsUnpromptedRead)
    definition.providerInternal = false
    definition.riskLevel = .reversible
    #expect(!definition.allowsUnpromptedRead)
  }
}
