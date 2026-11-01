import Foundation
import Testing
import OttoTools
@testable import OttoServices

private actor DraftApprovalFixture {
  var mail: [String: JSONValue] = ["id": .string("draft-1"), "subject": .string("Subject"),
    "body": .string("<p>Original body</p>"), "thread_id": .string("thread-1"),
    "reply_to_message_id": .string("original-message"),
    "to": .array([.object(["email": .string("recipient@example.com")])]),
    "cc": .array([]), "bcc": .array([]), "attachments": .array([])]
  var requests: [URLRequest] = []
  var failSend = false
  func change(_ key: String, _ value: JSONValue) { mail[key] = value }
  func fail() { failSend = true }
  func writes() -> [URLRequest] { requests.filter { $0.httpMethod != "GET" } }
  func respond(_ request: URLRequest) throws -> (Data, Int) {
    requests.append(request)
    var result: JSONValue
    if request.url!.path.hasSuffix("/grants") {
      result = .array([.object(["id": .string("grant-1"), "email": .string("work@example.com"), "grant_status": .string("valid")])])
    } else if request.url!.path.hasSuffix("/messages/send") {
      if failSend { throw URLError(.timedOut) }
      result = .object(["id": .string("sent-1")])
    } else {
      if request.httpMethod == "PUT", case .object(let payload) = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!) {
        mail.merge(payload) { _, new in new }
      }
      result = .object(mail)
    }
    return (try JSONEncoder().encode(JSONValue.object(["data": result])), 200)
  }
}

@Suite("Fenwick draft editing and exact send approval")
@MainActor struct FenwickDraftApprovalTests {
  private func setup(_ fixture: DraftApprovalFixture, path: String) -> FenwickInbox {
    let client = NylasClient(configuration: .init(credentialExecutable: "/unused", region: "us", accountsByProfileID: [:]),
      credential: { "test-only" }, transport: { try await fixture.respond($0) })
    return FenwickInbox(workspacePath: path, client: client, accounts: ["work@example.com"])
  }
  func read(_ inbox: FenwickInbox) async throws -> FenwickMailItem {
    try await inbox.read(account: "work@example.com", objectID: "draft-1", draft: true)
  }

  @Test("Save preserves reply identity, reads back all edits, and never sends")
  func save() async throws {
    let fixture = DraftApprovalFixture(); let inbox = setup(fixture, path: "/unused")
    let mail = try await read(inbox); var edit = FenwickDraftEdit(mail)
    edit.body = "Edited <safe> body"; edit.bcc = "hidden@example.com"; edit.subject = "Changed"
    let saved = try await inbox.saveDraft(mail, edit: edit)
    #expect(saved.body == edit.body && saved.bcc == edit.bcc && saved.subject == edit.subject)
    let writes = await fixture.writes()
    #expect(writes.count == 1 && writes[0].httpMethod == "PUT" && writes[0].url!.path.hasSuffix("/drafts/draft-1"))
    let payload = try JSONDecoder().decode(JSONValue.self, from: writes[0].httpBody!)
    #expect(payload["reply_to_message_id"] == .string("original-message"))
    #expect(payload["body"] == .string("Edited &lt;safe&gt; body"))
  }

  @Test("Cancel and stale approval do not send; external changes also block saves")
  func staleAndCancel() async throws {
    let fixture = DraftApprovalFixture(); let inbox = setup(fixture, path: "/unused")
    let mail = try await read(inbox)
    let review = try await inbox.prepareSend(mail)
    inbox.cancelSendReview()
    await #expect(throws: (any Error).self) { try await inbox.approveSend(review) }
    let fresh = try await inbox.prepareSend(mail)
    await fixture.change("bcc", .array([.object(["email": .string("changed@example.com")])]))
    await #expect(throws: (any Error).self) { try await inbox.approveSend(fresh) }
    await #expect(throws: (any Error).self) { try await inbox.saveDraft(mail, edit: FenwickDraftEdit(mail)) }
    #expect(await fixture.writes().isEmpty)
  }

  @Test("Approved exact payload sends once; replay and restart remain blocked")
  func exactOnce() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let fixture = DraftApprovalFixture(); let inbox = setup(fixture, path: path.path)
    let mail = try await read(inbox); let review = try await inbox.prepareSend(mail)
    #expect(review.text.contains("recipient@example.com") && review.text.contains("Original body"))
    #expect(await fixture.writes().isEmpty)
    try await inbox.approveSend(review)
    await #expect(throws: (any Error).self) { try await inbox.approveSend(review) }
    let restarted = setup(fixture, path: path.path)
    await #expect(throws: (any Error).self) { _ = try await restarted.prepareSend(mail) }
    await #expect(throws: (any Error).self) { _ = try await restarted.saveDraft(mail, edit: FenwickDraftEdit(mail)) }
    let writes = await fixture.writes()
    #expect(writes.count == 1 && writes[0].url!.path.hasSuffix("/messages/send"))
    let payload = try JSONDecoder().decode(JSONValue.self, from: writes[0].httpBody!)
    #expect(payload["body"] == .string(mail.body) && payload["reply_to_message_id"] == .string("original-message"))
    #expect(writes.allSatisfy { $0.httpMethod != "DELETE" })
  }

  @Test("Uncertain transport is never retried, including after reopening")
  func uncertain() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    let fixture = DraftApprovalFixture(); let inbox = setup(fixture, path: path.path)
    let mail = try await read(inbox); let review = try await inbox.prepareSend(mail)
    await fixture.fail()
    await #expect(throws: (any Error).self) { try await inbox.approveSend(review) }
    let restarted = setup(fixture, path: path.path)
    await #expect(throws: (any Error).self) { _ = try await restarted.prepareSend(mail) }
    #expect(await fixture.writes().count == 1)
  }

  @Test("Attachments, hidden recipient characters and unbound inboxes fail closed")
  func unsupported() async throws {
    let fixture = DraftApprovalFixture(); let inbox = setup(fixture, path: "/unused")
    await fixture.change("attachments", .array([.object(["id": .string("attachment")])]))
    let attachment = try await read(inbox)
    #expect(!attachment.canEdit)
    await #expect(throws: (any Error).self) { _ = try await inbox.prepareSend(attachment) }
    await #expect(throws: (any Error).self) { _ = try await inbox.saveDraft(attachment, edit: FenwickDraftEdit(attachment)) }
    await fixture.change("attachments", .array([]))
    let mail = try await read(inbox); var edit = FenwickDraftEdit(mail); edit.to = "a@example.com\nBcc: b@example.com"
    await #expect(throws: (any Error).self) { _ = try await inbox.saveDraft(mail, edit: edit) }
    #expect(await fixture.writes().isEmpty)
  }
}
