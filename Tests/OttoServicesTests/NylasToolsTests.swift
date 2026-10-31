import Foundation
import OttoApplicationTools
import OttoTools
import Testing
@testable import OttoServices

private actor NylasFixture {
  var requests: [URLRequest] = []
  var credentialReads = 0
  var starred = false
  func key() -> String { credentialReads += 1; return "test-key" }
  func respond(_ request: URLRequest) throws -> (Data, Int) {
    requests.append(request)
    let path = request.url!.path
    var response: JSONValue
    if path.hasSuffix("/grants") {
      response = .object(["data": .array([.object(["id": .string("current-grant"), "email": .string("work@example.com"), "grant_status": .string("valid"), "provider": .string("google")])])])
    } else if path.hasSuffix("/folders") {
      response = .object(["data": .array(["INBOX", "Label_1", "TRASH", "SENT"].map {
        .object(["id": .string($0), "name": .string($0)])
      })])
    } else if request.httpMethod == "PUT" {
      let value = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
      if case .bool(let value)? = value["starred"] { starred = value }
      response = .object(["data": value])
    } else {
      response = .object(["data": .object(["id": .string("message-1"), "subject": .string("Original"),
        "folders": .array([.string("INBOX"), .string("Label_existing")]), "unread": .bool(true), "starred": .bool(starred)])])
    }
    return (try JSONEncoder().encode(response), 200)
  }
  func all() -> [URLRequest] { requests }
  func keyCount() -> Int { credentialReads }
}

@Suite("Nylas scoped inbox tools")
struct NylasToolsTests {
  let configuration = NylasConfiguration(credentialExecutable: "/private/key-helper", region: "us", accountsByProfileID: [:])

  @Test("Reads and reversible edits are unprompted; sends and deletes are always confirmed")
  func permissions() async throws {
    #expect(NylasTool<NylasRead>.definition.allowsUnpromptedRead)
    #expect(NylasTool<NylasSearch>.definition.allowsUnpromptedRead)
    #expect(NylasTool<NylasDraft>.definition.allowsUnpromptedEdit)
    #expect(NylasTool<NylasSort>.definition.allowsUnpromptedEdit)
    #expect(!NylasTool<NylasSend>.definition.allowsUnpromptedEdit)
    #expect(!NylasTool<NylasDelete>.definition.allowsUnpromptedEdit)
    let registry = ToolRegistry()
    try await registry.register(NylasTool<NylasSend> { _, _ in Issue.record("Unapproved send executed"); return .null })
    try await registry.register(NylasTool<NylasDelete> { _, _ in Issue.record("Unapproved delete executed"); return .null })
    let context = ToolContext(actorID: "full-access-agent", scopes: [.agentRead], confirmed: false, source: .agent)
    for (tool, input) in [("nylas.send", ["account": "work@example.com", "to": "other@example.com", "subject": "hi", "body": "Hello"]),
      ("nylas.delete_permanently", ["account": "work@example.com", "messageID": "message-1", "expectedSubject": "Original"])] {
      await #expect(throws: ToolRegistryError.confirmationRequired(tool)) {
        try await registry.call(name: tool, input: .object(input.mapValues(JSONValue.string)), context: context)
      }
    }
  }

  @Test("One key resolution, no arbitrary inbox or HTTP endpoint, and identifiers are encoded")
  func boundAccounts() async throws {
    let fixture = NylasFixture()
    let client = NylasClient(configuration: configuration, credential: { await fixture.key() }, transport: { try await fixture.respond($0) })
    await #expect(throws: (any Error).self) {
      try await client.run(action: "read", input: .object(["account": .string("personal@example.com"), "messageID": .string("x")]), accounts: ["work@example.com"])
    }
    #expect(await fixture.all().isEmpty)
    for _ in 0..<2 {
      _ = try await client.run(action: "read", input: .object(["account": .string("work@example.com"), "messageID": .string("a/b?#")]), accounts: ["work@example.com"])
    }
    #expect(await fixture.keyCount() == 1)
    let url = try #require(await fixture.all().last?.url)
    #expect(url.host == "api.us.nylas.com")
    #expect(url.absoluteString.hasSuffix("messages/a%2Fb%3F%23"))
    #expect(url.path.contains("/grants/current-grant/"))
    #expect(throws: (any Error).self) { try configuration.accounts(for: UUID()) }
  }

  @Test("Draft writes can never take the send route; reply headers and all recipients are explicit")
  func draftRoutes() async throws {
    let fixture = NylasFixture()
    let client = NylasClient(configuration: configuration, credential: { await fixture.key() }, transport: { try await fixture.respond($0) })
    var input: [String: JSONValue] = ["account": .string("work@example.com"), "to": .string("a@example.com"),
      "cc": .string("b@example.com"), "bcc": .string("c@example.com"), "subject": .string("Re: Hi"),
      "body": .string("<img src='tracker'>\nHello"), "replyToMessageID": .string("original")]
    _ = try await client.run(action: "draft", input: .object(input), accounts: ["work@example.com"])
    input["draftID"] = .string("draft-1")
    _ = try await client.run(action: "draft", input: .object(input), accounts: ["work@example.com"])
    let requests = await fixture.all().filter { $0.httpMethod != "GET" }
    #expect(requests.map(\.httpMethod) == ["POST", "PUT"])
    #expect(requests[0].url!.path.hasSuffix("/drafts"))
    #expect(requests[1].url!.path.hasSuffix("/drafts/draft-1"))
    let payload = try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!)
    #expect(payload["reply_to_message_id"] == .string("original"))
    #expect(payload["body"]?.stringValue?.contains("&lt;img") == true)
    let card = try #require(EmailApprovalSummary.text(toolName: "nylas.send", input: input))
    for value in ["work@example.com", "a@example.com", "b@example.com", "c@example.com", "original", "Hello"] { #expect(card.contains(value)) }
  }

  @Test("Sort preserves unrelated labels, reads back, and refuses dangerous folders")
  func sorting() async throws {
    let fixture = NylasFixture()
    let client = NylasClient(configuration: configuration, credential: { await fixture.key() }, transport: { try await fixture.respond($0) })
    let base: [String: JSONValue] = ["account": .string("work@example.com"), "messageID": .string("message-1")]
    var input = base
    input["removeFolders"] = .array([.string("INBOX")])
    input["addFolders"] = .array([.string("Label_1")])
    input["starred"] = .bool(true)
    let result = try await client.run(action: "sort", input: .object(input), accounts: ["work@example.com"])
    #expect(result["before"]?["starred"] == .bool(false))
    #expect(result["after"]?["starred"] == .bool(true))
    let writes = await fixture.all().filter { $0.httpMethod == "PUT" }
    let payload = try JSONDecoder().decode(JSONValue.self, from: writes[0].httpBody!)
    #expect(payload["folders"] == .array([.string("Label_1"), .string("Label_existing")]))
    input = base; input["addFolders"] = .array([.string("TRASH")])
    await #expect(throws: (any Error).self) { try await client.run(action: "sort", input: .object(input), accounts: ["work@example.com"]) }
    #expect(await fixture.all().filter { $0.httpMethod == "PUT" }.count == 1)
  }

  @Test("Deletion refuses stale targets and hidden approval content; transport errors stay redacted")
  func failedActions() async throws {
    let fixture = NylasFixture()
    let client = NylasClient(configuration: configuration, credential: { await fixture.key() }, transport: { try await fixture.respond($0) })
    let input: [String: JSONValue] = ["account": .string("work@example.com"), "messageID": .string("message-1"), "expectedSubject": .string("Changed")]
    await #expect(throws: (any Error).self) { try await client.run(action: "delete_permanently", input: .object(input), accounts: ["work@example.com"]) }
    #expect(await fixture.all().allSatisfy { $0.httpMethod == "GET" })
    #expect(NylasDeleteApprovalSummary.refusal(input: ["account": .string("x"), "messageID": .string("x"), "expectedSubject": .string("visible\u{202E}hidden")]) != nil)
    #expect(EmailApprovalSummary.refusal(input: ["bcc": .string("a@example.com\nBcc: secret@example.com")]) != nil)
    let broken = NylasClient(configuration: configuration, credential: { "secret" }, transport: { _ in
      (Data("private provider failure".utf8), 401)
    })
    do { _ = try await broken.run(action: "accounts", input: .object([:]), accounts: ["work@example.com"]); Issue.record("Expected failure") }
    catch { #expect(!error.localizedDescription.contains("secret")); #expect(!error.localizedDescription.contains("private provider")) }
  }
}
