import Foundation
import OttoApplicationTools

extension ApplicationServices {
  /// Optional private bridge; no credentials or member identities are shipped in the app.
  func registerKnowledgeTools() async throws {
    let url = URL(fileURLWithPath: workspacePath).appending(path: ".otto/knowledge-bridge.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let configuration = try JSONDecoder().decode(
      KnowledgeBridgeConfiguration.self, from: Data(contentsOf: url))
    try await registry.register(KnowledgeReadTool(configuration: configuration,
      profileID: { [weak self] context in
        guard let self, let nodeID = context.sourceNodeID else { return nil }
        return await self.knowledgeProfileID(nodeID: nodeID)
      }))
  }

  private func knowledgeProfileID(nodeID: UUID) -> UUID? {
    store.snapshot.canvases.lazy.flatMap(\.nodes)
      .first(where: { $0.id == nodeID })?.agentDefinition?.profileID
  }
}
