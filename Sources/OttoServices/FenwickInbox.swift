import Combine
import CryptoKit
import OttoApplicationTools
import Foundation
import OttoRuntime
import OttoTools

public struct FenwickBriefSnapshot: Codable, Sendable {
  public let runID: String
  public let conclusion: String
  public let latestStatus: String
  public let latestRunID: String
  public let report: FenwickReport
}

public struct FenwickReport: Codable, Sendable {
  public let start: Double
  public let end: Double
  public let status: String
  public let accounts: [String: Coverage]
  public let decisions: [Item]
  public let errors: [String]
  public struct Coverage: Codable, Sendable {
    public let messages: Int
    public let archived: Int
  }
  public struct Item: Codable, Identifiable, Sendable {
    public var id: String { account + ":" + message.id }
    public let account: String
    public let message: Message
    public let decision: Decision
    public let draft: Draft?
    public struct Draft: Codable, Sendable { public let id: String?; public let status: String }
    public struct Message: Codable, Sendable {
      public let id: String
      public let subject: String?
      public let date: Double
      public let thread_id: String?
    }
    public struct Decision: Codable, Sendable {
      public let needs_attention: Bool
      public let reason: String
      public let next_action: String
      public let category: String
    }
  }
  public var attention: [Item] { decisions.filter { $0.decision.needs_attention } }
  public func includesDraft(account: String, id: String, threadID: String?) -> Bool {
    decisions.contains { item in
      item.account == account && (item.draft?.id == id ||
        (item.decision.needs_attention && threadID != nil && item.message.thread_id == threadID))
    }
  }
}

public struct FenwickMailItem: Identifiable, Sendable {
  public var id: String { account + ":" + objectID }
  public let account: String
  public let objectID: String
  public let threadID: String?
  public let subject: String
  public let to: String
  public let cc: String
  public let bcc: String
  public let from: String
  public let body: String
  public let attachmentCount: Int
  public let isDraft: Bool
  let original: JSONValue
  public var replyToMessageID: String? { original["reply_to_message_id"]?.stringValue }
  public var canEdit: Bool { isDraft && attachmentCount == 0 && (original["reply_to"]?.arrayValue ?? []).isEmpty }

  init(account: String, value: JSONValue, isDraft: Bool) throws {
    guard let id = value["id"]?.stringValue else { throw NylasError.unavailable("Mail identity unavailable.") }
    original = value
    self.account = account; objectID = id; self.isDraft = isDraft
    threadID = value["thread_id"]?.stringValue
    subject = value["subject"]?.stringValue ?? ""
    func addresses(_ key: String) -> String {
      (value[key]?.arrayValue ?? []).compactMap { $0["email"]?.stringValue }.joined(separator: ", ")
    }
    to = addresses("to"); cc = addresses("cc"); bcc = addresses("bcc"); from = addresses("from")
    let rawBody = value["body"]?.stringValue ?? value["snippet"]?.stringValue ?? ""
    body = value["is_plaintext"] == .bool(true) ? rawBody.trimmingCharacters(in: .whitespacesAndNewlines) : Self.plainText(rawBody)
    attachmentCount = value["attachments"]?.arrayValue?.count ?? 0
  }

  /// Inert text only: never load remote images, follow links or execute HTML from an email.
  static func plainText(_ html: String) -> String {
    var text = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li)\\s*>", with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
      text = text.replacingOccurrences(of: entity, with: replacement)
    }
    if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
      for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let range = Range(match.range(at: 1), in: text), let full = Range(match.range, in: text) else { continue }
        let digits = String(text[range]); let hex = digits.hasPrefix("x")
        if let value = UInt32(hex ? String(digits.dropFirst()) : digits, radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) {
          text.replaceSubrange(full, with: String(scalar))
        }
      }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct FenwickInboxConfiguration: Codable {
  let readerExecutable: String
  let readerScript: String
  let profileID: UUID
}

public struct FenwickDraftEdit: Equatable, Sendable {
  public var to: String
  public var cc: String
  public var bcc: String
  public var subject: String
  public var body: String
  public init(_ mail: FenwickMailItem) {
    to = mail.to; cc = mail.cc; bcc = mail.bcc; subject = mail.subject; body = mail.body
  }
}

/// An immutable, single-use approval prepared from a freshly checked saved draft.
public struct FenwickSendReview: Identifiable, Sendable {
  public let id: UUID
  public let mail: FenwickMailItem
  public let text: String
  fileprivate let input: JSONValue
  fileprivate let created: Date
}

/// Reversible draft editing, plus a separate exact-content human send approval.
/// Permanent deletion is deliberately not exposed by this surface.
@MainActor public final class FenwickInbox: ObservableObject {
  @Published public private(set) var snapshot: FenwickBriefSnapshot?
  @Published public private(set) var error: String?
  @Published public private(set) var refreshing = false
  @Published public private(set) var cached = false
  @Published public private(set) var drafts: [FenwickMailItem] = []
  @Published public private(set) var draftErrors: [String] = []
  @Published public private(set) var loadingDrafts = false
  @Published public private(set) var draftsLoaded = false
  private var pendingReview: FenwickSendReview?
  private var writing = false
  private let workspace: URL
  private var client: NylasClient?
  private var accounts: [String] = []

  public init(workspacePath: String) { workspace = URL(fileURLWithPath: workspacePath) }
  init(workspacePath: String, client: NylasClient, accounts: [String]) {
    workspace = URL(fileURLWithPath: workspacePath); self.client = client; self.accounts = accounts
  }
  public static func isConfigured(workspacePath: String) -> Bool {
    FileManager.default.fileExists(atPath: URL(fileURLWithPath: workspacePath).appending(path: ".otto/fenwick-inbox.json").path)
  }
  private var configURL: URL { workspace.appending(path: ".otto/fenwick-inbox.json") }
  private var cacheURL: URL { workspace.appending(path: ".otto/fenwick-brief-cache.json") }
  private func configuration() throws -> FenwickInboxConfiguration {
    try JSONDecoder().decode(FenwickInboxConfiguration.self, from: Data(contentsOf: configURL))
  }
  private func mailClient() throws -> NylasClient {
    if let client { return client }
    let config = try configuration()
    let nylas = try JSONDecoder().decode(NylasConfiguration.self, from: Data(contentsOf: workspace.appending(path: ".otto/nylas.json")))
    accounts = try nylas.accounts(for: config.profileID)
    let created = NylasClient(configuration: nylas); client = created; return created
  }
  static func decodeSnapshot(_ data: Data) throws -> FenwickBriefSnapshot {
    guard data.count <= 5_000_000 else { throw NylasError.unavailable("Brief exceeds safe size.") }
    let snapshot = try JSONDecoder().decode(FenwickBriefSnapshot.self, from: data)
    guard snapshot.report.end - snapshot.report.start == 86400,
      snapshot.report.start > 0, snapshot.report.end <= Date.now.timeIntervalSince1970 + 300,
      snapshot.report.attention.allSatisfy({ $0.message.date >= snapshot.report.start && $0.message.date < snapshot.report.end }) else {
      throw NylasError.unavailable("Brief has an invalid time window.")
    }
    return snapshot
  }
  public func refresh() async {
    guard !refreshing else { return }
    refreshing = true; defer { refreshing = false }
    do {
      _ = try mailClient()
      if snapshot == nil, let data = try? Data(contentsOf: cacheURL), let previous = try? Self.decodeSnapshot(data),
        Set(previous.report.accounts.keys).isSubset(of: Set(accounts)),
        previous.report.decisions.allSatisfy({ accounts.contains($0.account) }) {
        snapshot = previous; cached = true
      }
      let config = try configuration()
      guard config.readerExecutable.hasPrefix("/"), config.readerScript.hasPrefix("/") else {
        throw NylasError.unavailable("Cloud reader is not configured.")
      }
      guard let output = await ExecutableLocator.captureOutput(executable: config.readerExecutable,
        arguments: [config.readerScript, "--config", configURL.path], timeout: .seconds(150)),
        let data = output.data(using: .utf8) else {
        throw NylasError.unavailable("Couldn’t refresh the cloud brief. Check your connection and GitHub sign-in on this Mac.")
      }
      let result = try Self.decodeSnapshot(data)
      guard Set(result.report.accounts.keys).isSubset(of: Set(accounts)),
        result.report.decisions.allSatisfy({ accounts.contains($0.account) }) else {
        throw NylasError.unavailable("Brief contains an inbox outside Fenwick’s binding.")
      }
      snapshot = result; cached = false; error = nil
      try data.write(to: cacheURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    } catch {
      self.error = (error as? NylasError)?.localizedDescription ?? "Cloud brief unavailable. Saved results are not a fresh all-clear."
      cached = snapshot != nil
    }
  }
  public func refreshDrafts() async {
    guard !loadingDrafts else { return }
    loadingDrafts = true; draftsLoaded = false; drafts = []; draftErrors = []
    defer { loadingDrafts = false; draftsLoaded = true }
    do {
      let client = try mailClient()
      await client.allowCredentialRetryAfterFailure()
      for account in accounts {
        do {
          var cursor: String?; var seen = Set<String>()
          repeat {
            var input: [String: JSONValue] = ["account": .string(account)]
            if let cursor { input["cursor"] = .string(cursor) }
            let page = try await client.run(action: "drafts", input: .object(input), accounts: accounts)
            guard let rows = page["result"]?["data"]?.arrayValue else { throw NylasError.unavailable("Draft listing unavailable.") }
            for value in rows {
              let draft = try FenwickMailItem(account: account, value: value, isDraft: true)
              if !drafts.contains(where: { $0.id == draft.id }) { drafts.append(draft) }
            }
            cursor = page["result"]?["next_cursor"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted || seen.count > 30 { throw NylasError.unavailable("Draft listing incomplete.") }
          } while cursor != nil
        } catch {
          let reason = (error as? NylasError)?.localizedDescription ?? "Couldn’t read all drafts."
          draftErrors.append("\(account): \(reason) Refresh to try again.")
        }
      }
    } catch { draftErrors.append("Inbox connection unavailable. No empty-inbox claim is made.") }
  }
  public func read(account: String, objectID: String, draft: Bool) async throws -> FenwickMailItem {
    let client = try mailClient()
    await client.allowCredentialRetryAfterFailure()
    let value = try await client.run(action: draft ? "drafts" : "read",
      input: .object(["account": .string(account), draft ? "draftID" : "messageID": .string(objectID)]), accounts: accounts)
    guard let data = value["result"]?["data"] else { throw NylasError.unavailable("Mail is no longer available.") }
    return try FenwickMailItem(account: account, value: data, isDraft: draft)
  }
  public func cancelSendReview() { pendingReview = nil }

  private func draftFields(_ input: JSONValue) throws -> [String: JSONValue] {
    guard case .object(let fields) = input else { throw NylasError.unavailable("Invalid draft.") }; return fields
  }

  private func draftInput(_ mail: FenwickMailItem, _ edit: FenwickDraftEdit) throws -> JSONValue {
    guard mail.canEdit else { throw NylasError.unavailable("Drafts with attachments or a custom Reply-To remain read-only here.") }
    var fields: [String: JSONValue] = ["account": .string(mail.account), "to": .string(edit.to),
      "cc": .string(edit.cc), "bcc": .string(edit.bcc), "subject": .string(edit.subject), "body": .string(edit.body)]
    if let reply = mail.replyToMessageID { fields["replyToMessageID"] = .string(reply) }
    return .object(fields)
  }

  private func unchanged(_ expected: FenwickMailItem) async throws -> FenwickMailItem {
    let current = try await read(account: expected.account, objectID: expected.objectID, draft: true)
    // Compare raw content as well as displayed text: hidden HTML and recipient changes matter.
    let fields = ["id", "subject", "body", "to", "cc", "bcc", "from", "attachments", "reply_to",
                  "reply_to_message_id", "thread_id", "is_plaintext"]
    guard fields.allSatisfy({ current.original[$0] == expected.original[$0] }) else {
      throw NylasError.unavailable("This draft changed elsewhere. Reopen it and review the latest version before continuing.")
    }
    return current
  }

  public func saveDraft(_ original: FenwickMailItem, edit: FenwickDraftEdit) async throws -> FenwickMailItem {
    guard !writing else { throw NylasError.unavailable("Another draft action is still in progress.") }
    writing = true; pendingReview = nil; defer { writing = false }
    guard !FileManager.default.fileExists(atPath: attemptURL(original).path) else {
      throw NylasError.unavailable("A send was already attempted for this draft. Check Sent before editing or sending it again.")
    }
    var input = try draftFields(draftInput(original, edit))
    _ = try NylasClient.message(.object(input), sending: false)
    _ = try await unchanged(original)
    input["draftID"] = .string(original.objectID)
    let client = try mailClient()
    let result = try await client.run(action: "draft", input: .object(input), accounts: accounts)
    // Some providers replace the draft identity when saving.
    let id = result["result"]?["data"]?["id"]?.stringValue ?? original.objectID
    let saved = try await read(account: original.account, objectID: id, draft: true)
    var normalized = edit
    normalized.body = edit.body.trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = try NylasClient.message(try draftInput(saved, normalized), sending: false)
    let actual = try NylasClient.message(try draftInput(saved, FenwickDraftEdit(saved)), sending: false)
    guard expected == actual else { throw NylasError.unavailable("The saved draft did not match the edit. Reopen it before making another change.") }
    drafts.removeAll { $0.id == original.id || $0.id == saved.id }; drafts.append(saved)
    return saved
  }

  private func attemptURL(_ mail: FenwickMailItem) -> URL {
    let hash = SHA256.hash(data: Data(mail.id.utf8)).map { String(format: "%02x", $0) }.joined()
    return workspace.appending(path: ".otto/fenwick-send-attempts/" + hash + ".json")
  }

  public func prepareSend(_ mail: FenwickMailItem) async throws -> FenwickSendReview {
    guard !writing else { throw NylasError.unavailable("Another draft action is still in progress.") }
    writing = true; pendingReview = nil; defer { writing = false }
    let input = try draftInput(mail, FenwickDraftEdit(mail))
    _ = try NylasClient.message(input, sending: true)
    guard !FileManager.default.fileExists(atPath: attemptURL(mail).path) else {
      throw NylasError.unavailable("A send was already attempted for this draft. Check Sent before taking any further action; this view will not send it again.")
    }
    _ = try await unchanged(mail)
    let fields = try draftFields(input)
    guard let text = EmailApprovalSummary.text(toolName: "nylas.send", input: fields) else {
      throw NylasError.unavailable("Cannot display this email faithfully for approval.")
    }
    let threadNote = mail.replyToMessageID == nil ? "\n\nNo reply reference is available. This will send as a new message." : ""
    let review = FenwickSendReview(id: UUID(), mail: mail, text: text + threadNote, input: input, created: .now)
    pendingReview = review
    return review
  }

  public func approveSend(_ review: FenwickSendReview) async throws {
    guard !writing, let pending = pendingReview, pending.id == review.id,
      Date.now.timeIntervalSince(pending.created) < 600 else {
      throw NylasError.unavailable("A fresh explicit approval is required. Review the draft again.")
    }
    // Consume before any suspension: double-clicks, cancelled approvals and replay cannot send.
    pendingReview = nil; writing = true; defer { writing = false }
    _ = try await unchanged(pending.mail)
    let url = attemptURL(pending.mail)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // Exclusive durable reservation comes BEFORE the network write and survives app restart.
    try Data(#"{"status":"attempted","instruction":"Check Sent; never automatically retry"}"#.utf8)
      .write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let client = try mailClient(); let bound = accounts
    let tool = NylasTool<NylasSend> { input, _ in try await client.run(action: "send", input: input, accounts: bound) }
    do {
      let result = try await tool.call(pending.input,
        context: ToolContext(actorID: "fenwick-inbox-human", scopes: [.agentRead], confirmed: true, source: .userInterface))
      guard let id = result["result"]?["data"]?["id"]?.stringValue, !id.isEmpty else {
        throw NylasError.unavailable("No sent-message receipt returned.")
      }
      let receipt = try JSONEncoder().encode(["status": "sent", "messageID": id])
      try receipt.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      throw NylasError.unavailable("Send outcome needs checking in Sent. This draft is locked against another send here; no automatic retry was made.")
    }
  }

}
