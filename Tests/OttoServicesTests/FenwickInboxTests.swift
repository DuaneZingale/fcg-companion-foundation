import Foundation
import Testing
import OttoTools
@testable import OttoServices

private actor FenwickReadFixture {
  var requests: [URLRequest] = []
  func respond(_ request: URLRequest) throws -> (Data, Int) {
    requests.append(request)
    let mail: JSONValue = .object(["id": .string("draft-1"), "subject": .string("Review me"),
      "to": .array([.object(["email": .string("recipient@example.com")])]),
      "cc": .array([.object(["email": .string("copy@example.com")])]),
      "bcc": .array([.object(["email": .string("hidden@example.com")])]),
      "body": .string("<p>Unsent &amp; safe</p><img src='https://tracker.invalid'>")])
    let result: JSONValue
    if request.url!.path.hasSuffix("/grants") {
      result = .object(["data": .array([.object(["id": .string("grant-1"), "email": .string("work@example.com"), "grant_status": .string("valid")])])])
    } else if request.url!.path.hasSuffix("/drafts") {
      result = .object(["data": .array([mail])])
    } else { result = .object(["data": mail]) }
    return (try JSONEncoder().encode(result), 200)
  }
  func all() -> [URLRequest] { requests }
}

private actor FenwickRetryKey {
  var reads = 0
  func get() -> String? { reads += 1; return reads == 1 ? nil : "test-key" }
  func count() -> Int { reads }
}

@Suite("Fenwick native inbox review")
struct FenwickInboxTests {
  @Test("Credential timeouts remain closed until an explicit read refresh allows another lookup")
  func explicitCredentialRefresh() async throws {
    let key = FenwickRetryKey(); let fixture = FenwickReadFixture()
    let client = NylasClient(configuration: .init(credentialExecutable: "/unused", region: "us", accountsByProfileID: [:]),
      credential: { await key.get() }, transport: { try await fixture.respond($0) })
    let input: JSONValue = .object(["account": .string("work@example.com"), "draftID": .string("draft-1")])
    for _ in 0..<2 {
      await #expect(throws: (any Error).self) { try await client.run(action: "drafts", input: input, accounts: ["work@example.com"]) }
    }
    #expect(await key.count() == 1)
    #expect(await fixture.all().isEmpty)
    await client.allowCredentialRetryAfterFailure()
    _ = try await client.run(action: "drafts", input: input, accounts: ["work@example.com"])
    #expect(await key.count() == 2)
    #expect(await fixture.all().allSatisfy { $0.httpMethod == "GET" })
  }
  @Test("Review drafts and messages uses GET only and rejects an unbound account")
  @MainActor func reviewOnly() async throws {
    let fixture = FenwickReadFixture()
    let client = NylasClient(configuration: .init(credentialExecutable: "/unused", region: "us", accountsByProfileID: [:]),
      credential: { "test-only" }, transport: { try await fixture.respond($0) })
    let inbox = FenwickInbox(workspacePath: "/unused", client: client, accounts: ["work@example.com"])
    await inbox.refreshDrafts()
    #expect(inbox.draftsLoaded && inbox.draftErrors.isEmpty && inbox.drafts.count == 1)
    let draft = try await inbox.read(account: "work@example.com", objectID: "draft-1", draft: true)
    #expect(draft.isDraft && draft.to == "recipient@example.com")
    #expect(draft.cc == "copy@example.com" && draft.bcc == "hidden@example.com")
    #expect(draft.body == "Unsent & safe")
    _ = try await inbox.read(account: "work@example.com", objectID: "message-1", draft: false)
    await #expect(throws: (any Error).self) {
      try await inbox.read(account: "personal@example.com", objectID: "secret", draft: true)
    }
    #expect(await fixture.all().allSatisfy { $0.httpMethod == "GET" })
    #expect(await fixture.all().count == 4)
  }

  @Test("A failed draft listing is a visible gap, not an empty inbox")
  @MainActor func partialDrafts() async {
    let client = NylasClient(configuration: .init(credentialExecutable: "/unused", region: "us", accountsByProfileID: [:]),
      credential: { "test-only" }, transport: { _ in (Data(), 503) })
    let inbox = FenwickInbox(workspacePath: "/unused", client: client, accounts: ["work@example.com"])
    await inbox.refreshDrafts()
    #expect(inbox.draftsLoaded && !inbox.draftErrors.isEmpty)
  }

  @Test("Email HTML is inert text, with recipients and body preserved")
  func inertHTML() {
    let result = FenwickMailItem.plainText("<style>hidden</style><script>alert(1)</script><p>Hello&#x2014;there &lt;visible&gt;</p><img src='https://tracker.invalid'>Line<br>two")
    #expect(result == "Hello—there <visible>\nLine\ntwo")
  }

  @Test("Wrong window is rejected and failed cloud status stays failed")
  @MainActor func snapshotValidation() throws {
    func data(start: Int) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["runID": "42", "latestRunID": "42", "latestStatus": "completed", "conclusion": "failure",
        "report": ["start": start, "end": 186400, "status": "partial", "accounts": [:], "decisions": [], "errors": ["Read failed"]]])
    }
    #expect(throws: (any Error).self) { try FenwickInbox.decodeSnapshot(data(start: 1)) }
    let snapshot = try FenwickInbox.decodeSnapshot(data(start: 100000))
    #expect(snapshot.conclusion == "failure" && snapshot.report.errors == ["Read failed"])
  }

  @Test("Current draft review is matched by account and exact identity, excluding old drafts")
  func currentDraftScope() throws {
    let data = Data(#"{"start":100000,"end":186400,"status":"complete","accounts":{},"errors":[],"decisions":[{"account":"work@example.com","message":{"id":"mail","subject":"Hello","date":100001,"thread_id":"current-thread"},"decision":{"needs_attention":true,"reason":"Reply needed","next_action":"Review","category":"action"},"draft":{"id":"current-draft","status":"saved"}}]}"#.utf8)
    let report = try JSONDecoder().decode(FenwickReport.self, from: data)
    #expect(report.includesDraft(account: "work@example.com", id: "current-draft", threadID: nil))
    #expect(report.includesDraft(account: "work@example.com", id: "human-draft", threadID: "current-thread"))
    #expect(!report.includesDraft(account: "work@example.com", id: "old-draft", threadID: "old-thread"))
    #expect(!report.includesDraft(account: "other@example.com", id: "current-draft", threadID: "current-thread"))
  }
}
