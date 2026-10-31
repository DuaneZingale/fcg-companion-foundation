import Foundation
import OttoApplicationTools
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Full Access retains action gates")
struct FullAccessPolicyTests {
  @Test("Only Full Access grants ordinary reversible edits; it never grants the whole server",
    arguments: [AgentPermissionMode.readOnly, .workspaceWrite, .unrestricted])
  func providerGrants(mode: AgentPermissionMode) async throws {
    let request = AgentLaunchRequest(workspacePath: "/tmp", prompt: "Edit the note",
      permissionMode: mode, ottoMCPExecutable: "/usr/local/bin/otto-mcp",
      ottoSelfConfirmingTools: ["smtp.send", "terminal.run"],
      ottoReadOnlyTools: ["knowledge.read"], ottoReversibleTools: ["docs.edit"])
    let codex = try await CodexAdapter(executablePath: "/bin/echo").buildLaunchSpec(request)
    let claude = try await ClaudeCodeAdapter(executablePath: "/bin/echo").buildLaunchSpec(request)
    #expect(codex.arguments.contains { $0.contains("\"docs.edit\"={approval_mode=\"approve\"}") }
      == (mode == .unrestricted))
    #expect(claude.arguments.contains { $0.contains("mcp__otto__docs_edit") }
      == (mode == .unrestricted))
    for name in ["agent.ask_user", "agent.request_permission"] {
      #expect(codex.arguments.contains { $0.contains("\"\(name)\"={approval_mode=\"approve\"}") }
        == (mode == .unrestricted))
    }
    #expect(!codex.arguments.contains { $0.contains("default_tools_approval_mode") })
    #expect(!claude.arguments.contains("mcp__otto"))
    #expect(claude.arguments.contains("--permission-prompt-tool") == (mode != .unrestricted))
    #expect(!codex.arguments.contains { $0.contains("routine.delete") })
    #expect(TerminalRunTool.definition.requiresConfirmation)
  }

  @Test("Reversible edit grants exclude all external effects, explicit gates and destruction")
  func editEligibility() {
    var definition = KnowledgeReadTool.definition
    definition.riskLevel = .reversible
    #expect(definition.allowsUnpromptedEdit)
    for effect in [ToolExternalEffect.sendOrPublish, .delete, .spend, .accountChange] {
      definition.externalEffect = effect
      #expect(!definition.allowsUnpromptedEdit)
    }
    definition.externalEffect = nil
    definition.requiresConfirmation = true
    #expect(!definition.allowsUnpromptedEdit)
    definition.requiresConfirmation = false
    definition.requiredScopes = [.globalDestructive]
    #expect(!definition.allowsUnpromptedEdit)
    definition.requiredScopes = [.canvasWrite]
    definition.riskLevel = .destructive
    #expect(!definition.allowsUnpromptedEdit)
    definition.riskLevel = .reversible
    definition.providerInternal = true
    #expect(!definition.allowsUnpromptedEdit)
  }
}
