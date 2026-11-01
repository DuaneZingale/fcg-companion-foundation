import OttoServices
import SwiftUI

/// Native, read-only review surface; all consequential actions stay in the guarded chat tools.
struct FenwickInboxView: View {
  @StateObject private var inbox: FenwickInbox
  @Environment(\.dismiss) private var dismiss
  @Environment(\.ottoPalette) private var palette
  @State private var showingDrafts = false
  @State private var allDrafts = false
  @State private var draftSearch = ""
  @State private var selected: FenwickMailItem?
  @State private var reading = false
  @State private var readError: String?
  let openFenwick: () -> Void

  init(workspacePath: String, openFenwick: @escaping () -> Void) {
    _inbox = StateObject(wrappedValue: FenwickInbox(workspacePath: workspacePath))
    self.openFenwick = openFenwick
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Fenwick inbox").font(.ottoDisplay(25).weight(.semibold))
          Text("7 AM · Noon · 4 PM Central · Five inboxes · Last 24 hours")
            .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        }
        Spacer()
        Button("Open Fenwick chat") { dismiss(); openFenwick() }
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack {
        Button("Needs you") { showingDrafts = false; selected = nil; readError = nil }
          .disabled(!showingDrafts)
        Button("Review drafts") {
          showingDrafts = true; selected = nil; readError = nil
          if !inbox.draftsLoaded { Task { await inbox.refreshDrafts() } }
        }.disabled(showingDrafts)
        Spacer()
        if inbox.refreshing || inbox.loadingDrafts || reading { ProgressView().controlSize(.small) }
        Button("Refresh") {
          selected = nil; readError = nil
          Task { if showingDrafts { await inbox.refreshDrafts() } else { await inbox.refresh() } }
        }.disabled(inbox.refreshing || inbox.loadingDrafts || reading)
      }
      if let error = inbox.error { notice(error + (inbox.cached ? " Showing a saved brief." : "")) }
      if let error = readError { notice(error) }
      HSplitView {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if showingDrafts { draftList } else { briefList }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.frame(minWidth: 290, idealWidth: 340, maxWidth: 420)
        ScrollView {
          if let mail = selected { mailDetail(mail) }
          else {
            VStack(alignment: .leading, spacing: 12) {
              Image(systemName: showingDrafts ? "doc.text" : "envelope.open").font(.system(size: 28))
              Text(showingDrafts ? "Choose a draft to review" : "Choose an attention item")
                .font(.ottoDisplay(20))
              Text("Full message contents are read from your inbox when opened. Nothing is marked read, sent or deleted here.")
                .font(.ottoDisplay(14)).foregroundStyle(palette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
          }
        }.frame(minWidth: 330, maxWidth: .infinity)
      }
      Divider()
      Text("Drafts remain unsent. Ask Fenwick in chat to make changes or prepare a send. Sending and permanent deletion require a separate approval of the exact action.")
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
    }
    .padding(24)
    .foregroundStyle(palette.paper)
    .background(palette.workspaceSurface)
    .frame(minWidth: 850, idealWidth: 960, minHeight: 620, idealHeight: 720)
    .task {
      await inbox.refresh()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(300)) } catch { break }
        await inbox.refresh()
      }
    }
  }

  @ViewBuilder private var briefList: some View {
    if let snapshot = inbox.snapshot {
      let report = snapshot.report
      Text("Cloud brief · \(date(report.end))").font(.ottoDisplay(14).weight(.semibold))
      Text("\(date(report.start)) → \(date(report.end))")
        .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      Text("Attention as of this run. Open a message to read its current contents.")
        .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      if inbox.cached { notice("Saved copy — not verified fresh.") }
      if Date.now.timeIntervalSince1970 - report.end > 18 * 3600 { notice("This brief is over 18 hours old. Refresh or check the next cloud run.") }
      if snapshot.latestRunID != snapshot.runID { notice("A newer cloud run is \(snapshot.latestStatus). Showing the last completed report.") }
      if report.status != "complete" || snapshot.conclusion != "success" {
        notice("Coverage is incomplete. These results are not an all-clear.")
      }
      ForEach(report.errors, id: \.self) { notice($0) }
      if report.attention.isEmpty {
        Text(report.status == "complete" && snapshot.conclusion == "success" ? "No attention items in this report." : "No verified attention items yet.")
          .font(.ottoDisplay(15))
      }
      ForEach(report.attention) { item in
        Button {
          read(account: item.account, id: item.message.id, draft: false)
        } label: {
          VStack(alignment: .leading, spacing: 7) {
            Text(item.message.subject ?? "(No subject)").font(.ottoDisplay(15).weight(.semibold))
            Text(item.account).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            Text(item.decision.reason).font(.ottoDisplay(13))
            if !item.decision.next_action.isEmpty {
              Text("Next: \(item.decision.next_action)").font(.ottoDisplay(13)).foregroundStyle(palette.muted)
            }
            Text("Read message").font(.ottoDisplay(12)).foregroundStyle(palette.signal)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(14).ottoGlass(cornerRadius: 12)
        }.buttonStyle(.plain).disabled(reading)
      }
      Divider()
      Text("Coverage").font(.ottoDisplay(14).weight(.semibold))
      ForEach(report.accounts.keys.sorted(), id: \.self) { account in
        if let coverage = report.accounts[account] {
          VStack(alignment: .leading, spacing: 3) {
            Text(account).font(.ottoDisplay(12))
            Text("\(coverage.messages) reviewed · \(coverage.archived) archived")
              .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          }
        }
      }
    } else if !inbox.refreshing {
      Text("No cloud brief available yet.").font(.ottoDisplay(15))
    } else { Text("Fetching Fenwick’s cloud brief…").font(.ottoDisplay(15)) }
  }

  @ViewBuilder private var draftList: some View {
    Text(allDrafts ? "All saved drafts" : "Drafts for this brief").font(.ottoDisplay(18).weight(.semibold))
    Text(allDrafts ? "Includes earlier drafts. Reviewing these does not add old work to today’s attention list." : "Live drafts linked to attention items or saved replies in the current cloud brief.")
      .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
    Toggle("Include earlier saved drafts", isOn: $allDrafts)
      .font(.ottoDisplay(12)).onChange(of: allDrafts) { _, _ in selected = nil }
    TextField("Search drafts", text: $draftSearch).textFieldStyle(.roundedBorder)
    ForEach(inbox.draftErrors, id: \.self) { notice($0) }
    if inbox.loadingDrafts { Text("Reading saved drafts…") }
    if inbox.draftsLoaded && visibleDrafts.isEmpty && inbox.draftErrors.isEmpty {
      Text(allDrafts ? "No matching saved drafts." : "No saved drafts linked to this brief.")
    }
    ForEach(visibleDrafts) { draft in
      Button { read(account: draft.account, id: draft.objectID, draft: true) } label: {
        VStack(alignment: .leading, spacing: 6) {
          Text(draft.subject).font(.ottoDisplay(15).weight(.semibold))
          Text(draft.account).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          Text("To: \(draft.to.isEmpty ? "No recipient" : draft.to)").font(.ottoDisplay(12))
          Text("Review unsent draft").font(.ottoDisplay(12)).foregroundStyle(palette.signal)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).ottoGlass(cornerRadius: 12)
      }.buttonStyle(.plain).disabled(reading)
    }
  }

  private var visibleDrafts: [FenwickMailItem] {
    inbox.drafts.filter { draft in
      let current = inbox.snapshot?.report.includesDraft(account: draft.account, id: draft.objectID, threadID: draft.threadID) ?? false
      let matches = draftSearch.isEmpty || [draft.subject, draft.account, draft.to].contains { $0.localizedCaseInsensitiveContains(draftSearch) }
      return (allDrafts || current) && matches
    }
  }

  private func mailDetail(_ mail: FenwickMailItem) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(mail.isDraft ? "UNSENT DRAFT · LIVE READ" : "MESSAGE · LIVE READ")
        .font(.ottoMicro).foregroundStyle(palette.signal)
      Text(mail.subject).font(.ottoDisplay(22).weight(.semibold))
      Text("Inbox: \(mail.account)").font(.ottoDisplay(12))
      if !mail.from.isEmpty { Text("From: \(mail.from)").font(.ottoDisplay(12)) }
      Text("To: \(mail.to.isEmpty ? "No recipient" : mail.to)").font(.ottoDisplay(12))
      if !mail.cc.isEmpty { Text("Cc: \(mail.cc)").font(.ottoDisplay(12)) }
      if !mail.bcc.isEmpty { Text("Bcc: \(mail.bcc)").font(.ottoDisplay(12)) }
      if mail.attachmentCount > 0 { notice("\(mail.attachmentCount) attachment(s). Attachments are not displayed in this text review.") }
      Divider()
      Text(verbatim: mail.body.isEmpty ? "No message body returned." : mail.body)
        .font(.ottoDisplay(14)).textSelection(.enabled)
      Divider()
      Text("Reference: \(mail.objectID)").font(.ottoDisplay(11)).foregroundStyle(palette.muted).textSelection(.enabled)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
  }

  private func notice(_ text: String) -> some View {
    Text(verbatim: text).font(.ottoDisplay(12)).padding(10)
      .frame(maxWidth: .infinity, alignment: .leading).background(palette.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }
  private func date(_ timestamp: Double) -> String {
    let format = DateFormatter(); format.timeZone = TimeZone(identifier: "America/Chicago")
    format.dateFormat = "MMM d, h:mm a z"
    return format.string(from: Date(timeIntervalSince1970: timestamp))
  }
  private func read(account: String, id: String, draft: Bool) {
    reading = true; selected = nil; readError = nil
    Task {
      defer { reading = false }
      do { selected = try await inbox.read(account: account, objectID: id, draft: draft) }
      catch { readError = "Couldn’t read this \(draft ? "draft" : "message"). It may have changed or been removed. Refresh before reviewing." }
    }
  }
}
