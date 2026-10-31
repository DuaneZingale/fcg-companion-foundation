import OttoTools
import Testing
@testable import OttoMCP

@Suite("Nylas tool transport deadlines")
struct NylasTransportTimeoutTests {
  @Test("Inbox reads and writes retain their socket while bounded provider work is running")
  func deadlines() {
    for action in ["accounts", "search", "read", "folders", "drafts", "sort", "draft", "send", "delete_permanently"] {
      #expect(MCPBridge.toolTimeoutMilliseconds(name: "nylas." + action, arguments: .object([:])) == 600_000)
    }
    #expect(MCPBridge.toolTimeoutMilliseconds(name: "unknown.tool", arguments: .object([:])) == nil)
    #expect(MCPBridge.toolTimeoutMilliseconds(name: "terminal.wait", arguments: .object(["timeoutMilliseconds": .number(5_000)])) == 10_000)
  }
}
