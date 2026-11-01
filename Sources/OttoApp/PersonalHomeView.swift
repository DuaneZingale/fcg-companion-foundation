import AppKit
import OttoCore
import OttoModels
import OttoServices
import SwiftUI

/// A quiet landing place over real workspace data. Navigation and agent execution stay with
/// WorkspaceView; Home never copies conversations or invents activity.
struct PersonalHomeView: View {
  @ObservedObject var store: CanvasStore
  @ObservedObject var services: ApplicationServices
  @ObservedObject var activity: BotActivityStore
  @ObservedObject var brief: DailyBriefStore
  @Binding var draft: String
  @Binding var provider: AgentProvider
  @Binding var conversationTarget: HomeConversationTarget
  let openMarkdown: (String) -> Void
  let openBot: (AgentProfile) -> Void
  let openAgent: (UUID) -> Void
  let openCloud: () -> Void
  let openLibrary: (ChatSurfaceDestination) -> Void
  let hireBot: () -> Void
  let submit: (HomeConversationTarget, AgentProvider, String) async throws -> Void

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @AppStorage(OttoPreferenceKey.latestSelectedTheme) private var latestSelectedTheme = ""
  @State private var submitting = false
  @State private var error: String?
  @State private var pendingPastes: [ChatPastedText] = []
  @State private var pendingImages: [ChatImageAttachment] = []
  @FocusState private var composerFocused: Bool
  @State private var addingTodo = false
  @State private var briefError: String?
  @State private var settingUpBrief = false
  @State private var showingFenwickInbox = false
  @AppStorage(FirstRunPreferences.preferredName) private var preferredName = ""
  @AppStorage(FirstRunPreferences.gettingStartedActive) private var gettingStartedActive = false
  @AppStorage(FirstRunPreferences.gettingStartedDismissed) private var gettingStartedDismissed =
    false
  @AppStorage(FirstRunPreferences.starterBotID) private var starterBotID = ""
  @AppStorage(OttoBuddyPreferences.everShownKey) private var ottoOnScreenShown = false
  @AppStorage(FirstRunPreferences.voiceCommandUsed) private var voiceCommandUsed = false
  @AppStorage(OttoCommunityLinks.discordOpenedKey) private var discordOpened = false

  /// Home takes its colours from the active theme, exactly like Chat, so the two screens look
  /// like one app on light and dark backgrounds alike.
  @Environment(\.ottoPalette) private var palette
  private var ink: Color { palette.ink }
  private var muted: Color { palette.muted }
  private var accent: Color { palette.signal }
  /// The same single tint Chat lays over theme artwork.
  /// Cards and the composer keep the smoked-glass look on every theme: a dark plate with
  /// light text. Dark themes use their own colours; light themes borrow a dark palette.
  /// Light themes without artwork (Daylight) keep their own light cards. Light themes with
  /// artwork still borrow a dark plate so white card text stays legible over bright photos.
  private var cardsFollowTheme: Bool {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID).isPlainLight
  }
  private var cardPalette: OttoPalette {
    if cardsFollowTheme { return palette }
    let theme = OttoThemeCatalog.theme(id: store.activeCanvas.themeID)
    return theme.isLightAppearance ? OttoPalette(theme: OttoThemeCatalog.aurora) : palette
  }
  private var cardColorScheme: ColorScheme { cardsFollowTheme ? .light : .dark }
  /// Bright photos get denser smoke behind white card text; dark ones stay airy.
  private var cardSmoke: Double {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID).isLightAppearance ? 0.46 : 0.26
  }

  private var backdrop: Color {
    let theme = OttoThemeCatalog.theme(id: store.activeCanvas.themeID)
    let artwork =
      theme.backgroundAsset != nil && palette.surfaceMaterial != .windowGlass
      && palette.surfaceMaterial != .matte
    return artwork ? palette.artworkTint : palette.workspaceSurface
  }
  private var profile: HomeProfile { brief.selectedProfile }
  /// One theme for the whole app: Home always shows the active canvas's theme, so other pages
  /// look the same as Home. `applyProfileTheme` moves the canvas to the profile's choice.
  private var homeTheme: OttoThemeDefinition {
    OttoThemeCatalog.theme(id: store.activeCanvas.themeID)
  }
  private var desiredThemeID: String? {
    services.currentProfile?.themeID
      ?? (latestSelectedTheme.isEmpty ? nil : latestSelectedTheme)
  }
  private func applyProfileTheme() {
    guard let desired = desiredThemeID,
      OttoThemeCatalog.canonicalID(desired) ?? desired != store.activeCanvas.themeID
    else { return }
    store.dispatch(.setTheme(desired))
  }
  private func inProfile(nodeID: UUID) -> Bool {
    profile.includes(
      projectID: services.projectID(forNode: nodeID), legacyProjectID: services.legacyProjectID)
  }
  private var allRoster: [BotRosterEntry] { services.botRoster() }
  private var roster: [BotRosterEntry] {
    allRoster.filter { entry in
      let projectID = entry.channel.flatMap {
        services.conversationProjects.context(channelID: $0.id).projectID
      }
      return profile.includes(projectID: projectID, legacyProjectID: services.legacyProjectID)
    }
  }
  private var sessions: [OttoNode] {
    homeSessionNodes(
      canvases: store.snapshot.canvases,
      botProfileIDs: Set(allRoster.map { $0.profile.id }),
      botNodeIDs: Set(allRoster.compactMap(\.nodeID)),
      backgroundNodeIDs: services.office.boundSessionIDs
    ).filter { inProfile(nodeID: $0.id) }
  }
  private func dailyBrief(now: Date) -> DailyBrief {
    brief.compose(
      derived: services.derivedBriefItems(now: now), legacyProjectID: services.legacyProjectID,
      now: now)
  }
  private var conversationName: String {
    switch conversationTarget {
    case .newSession: "New session"
    case .bot(let id): allRoster.first { $0.profile.id == id }?.profile.name ?? "Unavailable bot"
    case .session(let id): sessions.first { $0.id == id }?.displayName ?? "Unavailable session"
    }
  }
  private var composerPlaceholder: String {
    conversationTarget == .newSession
      ? "Ask, make, or explore something…" : "Message \(conversationName)…"
  }
  private var conversationPicker: some View {
    Menu {
      Button {
        conversationTarget = .newSession
      } label: {
        Label("New session", systemImage: "plus.bubble")
      }
      if !roster.isEmpty {
        Section("Your bots") {
          ForEach(roster) { entry in
            Button(entry.profile.name) { conversationTarget = .bot(entry.profile.id) }
          }
        }
      }
      if !sessions.isEmpty {
        Section("Continue a session") {
          ForEach(sessions) { node in
            Button(node.displayName) { conversationTarget = .session(node.id) }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: conversationTarget == .newSession ? "plus.bubble" : "bubble.left")
        Text(conversationName).lineLimit(1)
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Home conversation")
    .accessibilityValue(conversationName)
    .disabled(submitting)
  }

  private var activeAgentCount: Int {
    services.fleet.values.filter { $0.state == .starting || $0.state == .working }.count
  }
  private var attention: [AgentAttentionItem] {
    services.attentionItems.filter { $0.state == .waitingPermission || $0.state == .waitingUser }
  }

  // Keep persisted decisions visible after a restart, deduplicating live runtime requests.
  private var recordedAttention: [BotActivityItem] {
    activity.needsUser.filter { item in
      let nodeID: UUID?
      switch item.deepLink {
      case .agent(let id): nodeID = id
      case .bot(let id, _): nodeID = allRoster.first { $0.profile.id == id }?.nodeID
      default: nodeID = nil
      }
      return !attention.contains { $0.nodeID == nodeID }
    }
  }
  private var attentionCount: Int {
    attention.count + recordedAttention.count + services.homeReviews.open.count
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      content(now: timeline.date)
    }
    .onAppear(perform: applyProfileTheme)
    .sheet(isPresented: $showingFenwickInbox) {
      FenwickInboxView(workspacePath: services.defaultWorkspacePath) {
        if let entry = allRoster.first(where: { $0.profile.name.localizedCaseInsensitiveContains("Fenwick") }) {
          openBot(entry.profile)
        }
      }
    }
    // Accounts signed in since the brief was set up get their own morning run.
    .task(id: profile.id) {
      _ = try? await services.syncMorningBriefAccounts(profileID: profile.id)
    }
    .onReceive(services.providerAccounts.objectWillChange) { _ in
      let id = profile.id
      Task { _ = try? await services.syncMorningBriefAccounts(profileID: id) }
    }
  }

  private func content(now: Date) -> some View {
    let today = dailyBrief(now: now)
    return GeometryReader { geometry in
      ZStack(alignment: .top) {
        // The theme photo is drawn once behind every screen; Home adds the same tint as Chat.
        backdrop.ignoresSafeArea()
        ScrollView {
          VStack(spacing: 0) {
            hero(today, now: now)
              .padding(.top, geometry.size.height < 720 ? 90 : 140)
              .padding(.bottom, 44)
            HomeReviewsView(reviews: services.homeReviews, services: services, openAgent: openAgent)
              .environment(\.ottoPalette, cardPalette)
              .environment(\.colorScheme, cardColorScheme)
            if !today.isEmpty || addingTodo {
              briefView(today, now: now, width: geometry.size.width).padding(.bottom, 40)
            } else if profile.briefRoutineID == nil {
              briefSetupRow.frame(maxWidth: 620).padding(.bottom, 36)
            }
            workspaceCards(width: geometry.size.width, briefIsEmpty: today.isEmpty)
            footer
              .padding(.top, 26)
              .padding(.bottom, 30)
          }
          .frame(maxWidth: 920)
          .padding(.horizontal, 36)
          .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        topBar
      }
      .foregroundStyle(palette.paper.opacity(0.92))
      .environment(\.ottoGlassSmoke, cardSmoke)
      .environment(\.ottoGlassLight, cardsFollowTheme)
    }
  }

  private var topBar: some View {
    // The window's own controls (traffic lights, Home/Chat) own the left; Home's controls sit
    // on the right so nothing overlaps them.
    HStack(spacing: 14) {
      Spacer()
      if FenwickInbox.isConfigured(workspacePath: services.defaultWorkspacePath) {
        Button { showingFenwickInbox = true } label: {
          Label("Fenwick inbox", systemImage: "tray.full")
            .font(.ottoDisplay(12))
        }.accessibilityLabel("Open Fenwick inbox briefs and drafts")
      }
      OttoHeaderControls(
        services: services, store: store, needsAttention: attentionCount > 0,
        openActivity: { openLibrary(.activity) }
      )
      .homeTourTarget(.spaceSwitcher)
      .padding(.trailing, 18)
    }
    .buttonStyle(.plain)
    .frame(height: 34)
    // Theme-derived band and glyphs, shared with Chat's header (see OttoPalette.chromeBand).
    .background(palette.chromeBand)
  }

  private func hero(_ today: DailyBrief, now: Date) -> some View {
    VStack(spacing: 12) {
      // Text straight on the photo: full-strength theme text plus a soft halo, not a wash.
      Group {
        Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
          .font(.ottoMicro)
          .tracking(2.6)
          .foregroundStyle(palette.paper.opacity(0.85))
        Text(today.isEmpty && preferredName.isEmpty ? "What’s on your mind?" : greeting(now))
          .font(.ottoDisplay(34).weight(.semibold))
          .tracking(-0.8)
          .multilineTextAlignment(.center)
          .foregroundStyle(palette.paper)
          .homeTourTarget(.greeting)
        Text(today.headline ?? "A place for your ideas, your people, and whatever comes next.")
          .font(.ottoDisplay(13).weight(.medium))
          .foregroundStyle(palette.paper.opacity(0.9))
          .multilineTextAlignment(.center)
      }
      .shadow(color: palette.textHalo, radius: 8)
      composer.homeTourTarget(.composer).padding(.top, 14)
      HStack(spacing: 18) {
        Button {
          addingTodo = true
        } label: {
          Label("To-do", systemImage: "plus.circle").font(.ottoDisplay(11).weight(.medium))
            .foregroundStyle(palette.paper.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a to-do to today’s brief")
        shortcut("Files & notes", symbol: "doc.text", destination: .files)
        shortcut("Automations", symbol: "clock", destination: .routines)
        Button(action: openCloud) {
          Label("Cloud", systemImage: "cloud").font(.ottoDisplay(11).weight(.medium))
            .foregroundStyle(palette.paper.opacity(0.85))
        }.buttonStyle(.plain)
      }
      .shadow(color: palette.textHalo, radius: 6)
      .homeTourTarget(.shortcuts)
      .padding(.top, 5)
    }
    .frame(maxWidth: 620)
    .frame(maxWidth: .infinity)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !pendingPastes.isEmpty || !pendingImages.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 7) {
            ForEach(pendingPastes) { paste in
              ChatPastedTextChip(
                paste: paste, scale: 1.3, foreground: cardPalette.muted,
                background: cardPalette.paper.opacity(0.08)
              ) {
                pendingPastes.removeAll { $0.id == paste.id }
              }
            }
            ForEach(pendingImages) { image in
              HStack(spacing: 6) {
                if let thumbnail = NSImage(contentsOfFile: image.path) {
                  Image(nsImage: thumbnail)
                    .resizable().scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(image.name).font(.ottoDisplay(10)).lineLimit(1)
                Button {
                  pendingImages.removeAll { $0.id == image.id }
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(image.name)")
              }
              .foregroundStyle(cardPalette.muted)
              .padding(7)
              .background(cardPalette.paper.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
          }
        }
        .scrollIndicators(.hidden)
        .frame(height: 48)
        .disabled(submitting)
      }
      TextField(composerPlaceholder, text: $draft, axis: .vertical)
        .font(.ottoDisplay(15))
        .textFieldStyle(.plain)
        // Typed text follows the composer's own colours, never the photo-dependent page ink,
        // or light themes write dark text on the dark plate.
        .foregroundStyle(cardPalette.paper)
        .tint(cardPalette.signal)
        .lineLimit(2...)
        .composerScroll(maxHeight: 190)
        .focused($composerFocused)
        .onSubmit(send)
        .accessibilityLabel("Home task")
        .disabled(submitting)
        // Large pastes become chips so the field stays short and typing stays fast.
        .background {
          ChatComposerKeyMonitor(
            isEnabled: composerFocused && !submitting,
            onPasteImage: attachImagesFromPasteboard,
            onPasteLargeText: attachTextFromPasteboard
          )
        }
      HStack(spacing: 8) {
        conversationPicker
        Spacer()
        if conversationTarget == .newSession {
          Menu {
            ForEach(
              [AgentProvider.codex, .claudeCode, .hermes, .kimi, .cursor, .openCode, .pi, .grok],
              id: \.self
            ) { option in
              Button(option.rawValue) { provider = option }
            }
          } label: {
            HStack(spacing: 5) {
              Text(provider.rawValue)
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .accessibilityLabel("Home agent provider")
          .disabled(submitting)
        } else {
          Text("Saved conversation").lineLimit(1)
        }
        Button(action: send) {
          Group {
            if submitting {
              ProgressView().controlSize(.mini)
            } else {
              Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
            }
          }
          .frame(width: 30, height: 30)
          .foregroundStyle(cardPalette.ink)
          .background(cardPalette.signal, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(submitting || composedPrompt == nil)
        .opacity(composedPrompt == nil ? 0.4 : 1)
        .accessibilityLabel("Start home task")
        .help(
          conversationTarget == .newSession ? "Start a new session" : "Send to this conversation")
      }
      .font(.ottoDisplay(10))
      .foregroundStyle(cardPalette.muted)
      if let error {
        Text(error).font(.ottoDisplay(11)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(18)
    // The composer is a solid plate in the card colours, whatever the photo behind it.
    .background(
      cardPalette.ink.opacity(reduceTransparency ? 1 : 0.94),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(cardPalette.paper.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    .environment(\.colorScheme, cardColorScheme)
  }

  private func shortcut(_ title: String, symbol: String, destination: ChatSurfaceDestination)
    -> some View
  {
    Button {
      openLibrary(destination)
    } label: {
      Label(title, systemImage: symbol).font(.ottoDisplay(11).weight(.medium))
        .foregroundStyle(palette.paper.opacity(0.85))
    }
    .buttonStyle(.plain)
  }

  private func greeting(_ now: Date) -> String {
    let hour = Calendar.current.component(.hour, from: now)
    let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
    let first =
      FirstRunPreferences.preferredFirstName
      ?? NSFullUserName().split(separator: " ").first.map(String.init)
    return first.map { "\(part), \($0)" } ?? part
  }

  private func briefView(_ today: DailyBrief, now: Date, width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HomeBriefView(
        brief: today, now: now, sideBySide: width >= 900, addingTodo: $addingTodo,
        complete: { item in
          do { try brief.setCompleted(item.id, true) } catch {
            briefError = error.localizedDescription
          }
        },
        dismiss: { item in
          do { try brief.dismiss(item.id) } catch { briefError = error.localizedDescription }
        },
        addTodo: { title in _ = try brief.addTodo(title: title, profileID: profile.id) },
        perform: perform,
        prep: { event in
          conversationTarget = .newSession
          let when =
            event.time.map { " at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
          draft =
            "Prep me for “\(event.title)”\(when). Pull together who is attending, what we last discussed, open questions and what I should decide. Use my connected tools; don’t send anything."
        },
        workOn: { item, botID in workOn(item, botID: botID) },
        bots: allRoster.map { (id: $0.profile.id, name: $0.profile.name) }
      )
      .environment(\.ottoPalette, cardPalette)
      .environment(\.colorScheme, cardColorScheme)
      briefSetupRow
      if let briefError {
        Text(briefError).font(.ottoDisplay(11)).foregroundStyle(muted)
          .padding(.horizontal, 14)
      }
    }
  }

  /// One quiet line that connects the profile's tools to the brief, or says when it next runs.
  @ViewBuilder private var briefSetupRow: some View {
    let routine = profile.briefRoutineID.flatMap { services.routines.routine(id: $0) }
    HStack(spacing: 10) {
      Image(systemName: routine == nil ? "calendar.badge.plus" : "sunrise")
        .foregroundStyle(muted)
      if let routine {
        Text(
          routine.enabled
            ? "Morning brief runs \(scheduleLabel(routine)) with \(routineAgentName(routine.target))"
              + briefAccountsLabel
            : "Morning brief is paused"
        )
        .lineLimit(1)
        Spacer()
        Button(settingUpBrief ? "Running…" : "Run now") { runBrief() }
          .disabled(settingUpBrief)
        Button("Change") { openLibrary(.routines) }
      } else {
        Text("Add your calendar, inbox and tasks: choose who reads them each morning.")
          .lineLimit(2)
        Spacer()
        Menu {
          if !allRoster.isEmpty {
            Section("Your bots") {
              ForEach(allRoster) { entry in
                Button(entry.profile.name) {
                  setUpBrief(.spawnProfile(profileID: entry.profile.id))
                }
              }
            }
          }
          Section("A fresh agent") {
            ForEach([AgentProvider.claudeCode, .codex], id: \.self) { option in
              Button(option.rawValue) { setUpBrief(.spawnProvider(provider: option.rawValue)) }
            }
          }
        } label: {
          Text(settingUpBrief ? "Setting up…" : "Set up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(settingUpBrief)
        .accessibilityLabel("Set up the morning brief")
      }
    }
    .buttonStyle(.plain)
    .font(.ottoDisplay(10).weight(.medium))
    .foregroundStyle(palette.paper.opacity(0.85))
    .shadow(color: palette.textHalo, radius: 6)
    .padding(.horizontal, 14)
  }

  /// Says how many accounts the brief reads when it is more than one.
  private var briefAccountsLabel: String {
    let count = services.morningBriefRoutines(profileID: profile.id).count
    return count > 1 ? " across \(count) accounts" : ""
  }

  private func scheduleLabel(_ routine: Routine) -> String {
    guard case .schedule(let cron?, _) = routine.trigger else { return "each morning" }
    let fields = cron.split(separator: " ")
    guard fields.count >= 2, let minute = Int(fields[0]), let hour = Int(fields[1]) else {
      return "each morning"
    }
    return String(format: "daily at %02d:%02d", hour, minute)
  }

  private func routineAgentName(_ target: RoutineTarget) -> String {
    switch target {
    case .spawnProfile(let id): services.agentProfiles.profile(id: id)?.name ?? "a bot"
    case .spawnProvider(let provider): provider
    case .existingAgent(let id): agentName(id)
    }
  }

  private func setUpBrief(_ target: RoutineTarget) {
    settingUpBrief = true
    let profileID = profile.id
    Task {
      do {
        _ = try await services.setUpMorningBrief(profileID: profileID, target: target)
        briefError = nil
      } catch {
        briefError = error.localizedDescription
        settingUpBrief = false
        return
      }
      settingUpBrief = false
      runBrief()
    }
  }

  /// Runs the brief now on every account it reads.
  private func runBrief() {
    settingUpBrief = true
    let profileID = profile.id
    Task {
      do {
        try await services.syncMorningBriefAccounts(profileID: profileID)
        var skipped: String?
        for routine in services.morningBriefRoutines(profileID: profileID) {
          let output = try await services.testRoutine(id: routine.id)
          if !output.fired, skipped == nil { skipped = Self.routineSkipMessage(output.reason) }
        }
        briefError = skipped
      } catch { briefError = error.localizedDescription }
      settingUpBrief = false
    }
  }

  private func perform(_ action: BriefAction) {
    switch action {
    case .openAgent(let id): openAgent(id)
    case .openActivity: openLibrary(.activity)
    case .openRoutine: openLibrary(.routines)
    case .openURL(let raw):
      if let url = URL(string: raw), url.scheme == "https" { NSWorkspace.shared.open(url) }
    }
  }

  private func workspaceCards(width: CGFloat, briefIsEmpty: Bool) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      if showsGettingStarted {
        gettingStartedCard.homeTourTarget(.gettingStarted)
      }
      HomeCardsView(
        cards: services.homeCards, services: services,
        openAutomations: { openLibrary(.routines) }
      )
      .environment(\.ottoPalette, cardPalette)
      .environment(\.colorScheme, cardColorScheme)
      HomePinnedCards(
        services: services, openMarkdown: openMarkdown,
        profileID: nil
      )
      .environment(\.ottoPalette, cardPalette)
      .environment(\.colorScheme, cardColorScheme)
      // Decisions now lead the brief, so the reassurance card only shows when there are none.
      if briefIsEmpty, width >= 760 {
        HStack(alignment: .top, spacing: 14) {
          agentsCard.frame(maxWidth: .infinity)
          attentionCard.frame(maxWidth: .infinity)
        }
      } else if briefIsEmpty {
        agentsCard
        attentionCard
      } else {
        agentsCard
      }
    }
  }

  // MARK: Getting started

  private var starterBot: BotRosterEntry? {
    roster.first { $0.profile.id.uuidString == starterBotID } ?? roster.first
  }

  private var gettingStartedItems: [GettingStartedItem] {
    GettingStartedProgress.items(
      GettingStartedState(
        hasPreferredName: !preferredName.trimmingCharacters(in: .whitespaces).isEmpty,
        hasBot: !roster.isEmpty,
        hasGivenTask: !activity.items.isEmpty || !services.runHistory.isEmpty,
        hasUsedVoiceCommand: voiceCommandUsed,
        hasMorningBrief: profile.briefRoutineID != nil,
        hasJoinedCommunity: discordOpened,
        hasMetOttoOnScreen: ottoOnScreenShown),
      botName: starterBot?.profile.name)
  }

  /// Only for people who came through the new welcome, until they finish or hide it.
  private var showsGettingStarted: Bool {
    gettingStartedActive && !gettingStartedDismissed
      && gettingStartedItems.contains { !$0.isComplete }
  }

  private var gettingStartedCard: some View {
    let items = gettingStartedItems
    let done = items.filter(\.isComplete).count
    return panel(minHeight: 0) {
      HStack {
        Label("Getting started", systemImage: "flag.checkered")
          .font(.ottoDisplay(13).weight(.medium))
        Spacer()
        Text("\(done) OF \(items.count)")
          .font(.ottoMicro)
          .tracking(1.4)
          .foregroundStyle(cardPalette.muted)
        Button("Hide") { gettingStartedDismissed = true }
          .buttonStyle(.plain)
          .font(.ottoDisplay(10))
          .foregroundStyle(cardPalette.muted)
          .help("Hide this checklist")
      }
      ProgressView(value: Double(done), total: Double(items.count))
        .tint(cardPalette.signal)
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)],
        alignment: .leading, spacing: 10
      ) {
        ForEach(items) { item in gettingStartedRow(item) }
      }
    }
    .accessibilityIdentifier("home.getting-started")
  }

  private func gettingStartedRow(_ item: GettingStartedItem) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 14))
        .foregroundStyle(item.isComplete ? cardPalette.signal : cardPalette.muted)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.ottoDisplay(12))
          .strikethrough(item.isComplete)
          .foregroundStyle(item.isComplete ? cardPalette.muted : cardPalette.paper)
        if !item.isComplete, let detail = gettingStartedDetail(item) {
          Text(detail).font(.ottoDisplay(10)).foregroundStyle(cardPalette.muted)
        }
      }
      Spacer(minLength: 0)
      if !item.isComplete, let action = gettingStartedAction(item) {
        Button(action.title, action: action.perform)
          .buttonStyle(.plain)
          .font(.ottoDisplay(10).weight(.semibold))
          .foregroundStyle(cardPalette.signal)
          .disabled(settingUpBrief)
      }
    }
  }

  private func gettingStartedDetail(_ item: GettingStartedItem) -> String? {
    item.id == .voiceCommand ? "Press ⌃⌥Space. Speech stays on this Mac" : item.detail
  }

  private func gettingStartedAction(_ item: GettingStartedItem)
    -> (title: String, perform: () -> Void)?
  {
    switch item.id {
    case .hireAgent: return ("Hire", hireBot)
    case .firstTask: return ("Write it", { composerFocused = true })
    case .morningBrief:
      return (
        "Set up",
        {
          setUpBrief(
            starterBot.map { .spawnProfile(profileID: $0.profile.id) }
              ?? .spawnProvider(provider: AgentProvider.claudeCode.rawValue))
        }
      )
    case .joinCommunity: return ("Join", { OttoCommunityLinks.openDiscord() })
    case .ottoOnScreen:
      return (
        "Turn on", { UserDefaults.standard.set(true, forKey: OttoBuddyPreferences.enabledKey) }
      )
    case .aboutYou, .voiceCommand: return nil
    }
  }

  private var agentsCard: some View {
    panel(minHeight: roster.isEmpty ? 0 : 196) {
      HStack {
        Label("Your agents", systemImage: "person.2").font(.ottoDisplay(13).weight(.medium))
        Spacer()
        Button(action: hireBot) { Image(systemName: "plus") }
          .buttonStyle(.plain).foregroundStyle(cardPalette.muted)
          .accessibilityLabel("Hire an agent from Home")
      }
      if roster.isEmpty {
        Text("No bots yet. Hire one to give it a place here.")
          .font(.ottoDisplay(12)).foregroundStyle(cardPalette.muted)
      } else {
        ForEach(roster.prefix(3)) { entry in
          Button {
            openBot(entry.profile)
          } label: {
            HStack(spacing: 11) {
              BotAvatarView(
                presentation: BotAvatarPresentation(
                  id: entry.profile.id, name: entry.profile.name, appearance: entry.appearance,
                  photoURL: services.botPhotoURL(entry.appearance?.photoRelativePath),
                  state: entry.avatarState),
                size: 30)
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.profile.name).font(.ottoDisplay(12).weight(.medium))
                Text(entry.profile.jobTitle ?? entry.profile.role)
                  .font(.ottoDisplay(10)).foregroundStyle(cardPalette.muted).lineLimit(1)
              }
              Spacer()
              Text(
                entry.needsYou
                  ? "Needs you" : entry.avatarState == .working ? "Working" : "Open chat"
              )
              .font(.ottoDisplay(9))
              .foregroundStyle(entry.needsYou ? cardPalette.signal : cardPalette.muted)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Home chat with \(entry.profile.name)")
        }
      }
    }
  }

  private var attentionCard: some View {
    panel {
      HStack {
        Label("Needs you", systemImage: "circle.dotted").font(.ottoDisplay(13).weight(.medium))
        Spacer()
        if attentionCount > 0 {
          Text("\(attentionCount)").font(.ottoMono(10)).foregroundStyle(cardPalette.signal)
        }
      }
      if attentionCount == 0 {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "checkmark.circle").font(.system(size: 23, weight: .ultraLight))
            .foregroundStyle(cardPalette.signal)
          VStack(alignment: .leading, spacing: 5) {
            Text("You’re all caught up.").font(.ottoDisplay(14))
            Text("When an agent needs a decision, it will find you here.")
              .font(.ottoDisplay(11)).foregroundStyle(cardPalette.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, 15)
      } else {
        ForEach(attention.prefix(3)) { item in
          Button {
            openAgent(item.nodeID)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(agentName(item.nodeID)).font(.ottoDisplay(12).weight(.medium))
              Text(item.reason).font(.ottoDisplay(11)).foregroundStyle(cardPalette.muted).lineLimit(
                2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Review \(agentName(item.nodeID))")
        }
      }
      let waitingReviews = services.homeReviews.open.count
      if waitingReviews > 0 {
        VStack(alignment: .leading, spacing: 4) {
          Text(waitingReviews == 1 ? "1 draft to review" : "\(waitingReviews) drafts to review")
            .font(.ottoDisplay(12).weight(.medium))
          Text("Approve, comment on or reject them under For your review.")
            .font(.ottoDisplay(11)).foregroundStyle(cardPalette.muted).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(recordedAttention.prefix(max(0, 3 - attention.count))) { item in
        Button {
          openLibrary(.activity)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.ottoDisplay(12).weight(.medium))
            Text(item.detail ?? "A saved decision is waiting for review.")
              .font(.ottoDisplay(11)).foregroundStyle(cardPalette.muted).lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Review saved decision")
      }
      Button {
        openLibrary(.activity)
      } label: {
        HStack {
          Text("View activity")
          Spacer()
          Image(systemName: "arrow.right")
        }
        .font(.ottoDisplay(10)).foregroundStyle(cardPalette.muted)
      }
      .buttonStyle(.plain)
    }
  }

  /// Routine skips arrive as engine codes; say what they mean.
  static func routineSkipMessage(_ reason: String?) -> String? {
    switch reason {
    case nil: nil
    case "overlap": "Already running. The results will land here when it finishes."
    case let other?: "The brief didn’t run: \(other)."
    }
  }

  private func panel<Content: View>(
    minHeight: CGFloat = 196, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 16, content: content)
      .padding(18)
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
      .ottoGlass(cornerRadius: 12)
      .foregroundStyle(cardPalette.paper)
      .environment(\.ottoPalette, cardPalette)
      .environment(\.colorScheme, cardColorScheme)
  }

  private var footer: some View {
    HStack(spacing: 7) {
      Circle().fill(accent.opacity(0.7)).frame(width: 4, height: 4)
      Text("\(activeAgentCount) ACTIVE · \(attentionCount) NEEDS YOU")
        .font(.ottoMicro).tracking(1.8)
      Spacer()
      Text("Make yourself at home.").font(.ottoDisplay(11))
    }
    .foregroundStyle(palette.paper.opacity(0.8))
    .shadow(color: palette.textHalo, radius: 6)
  }

  private func agentName(_ id: UUID) -> String {
    guard let node = store.snapshot.canvases.flatMap(\.nodes).first(where: { $0.id == id }) else {
      return "Agent"
    }
    return node.kind == .terminal ? "Terminal · \(node.displayName)" : node.displayName
  }

  private var composedPrompt: String? {
    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    return ChatImageAttachmentStore.compose(
      typed: typed.isEmpty ? nil : typed, pastes: pendingPastes, images: pendingImages)
  }

  private func attachImagesFromPasteboard() {
    error = nil
    let directory = (services.defaultWorkspacePath as NSString).appendingPathComponent(
      ".otto/chat-attachments")
    do {
      pendingImages.append(
        contentsOf: try ChatImageAttachmentStore(directory: directory).paste(from: .general))
    } catch {
      self.error = "Couldn’t attach image: \(error.localizedDescription)"
    }
  }

  private func attachTextFromPasteboard() {
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    pendingPastes.append(ChatPastedText(text))
  }

  /// Starts an agent on a brief item with everything the brief knows about it.
  private func workOn(_ item: BriefItem, botID: UUID?) {
    guard !submitting else { return }
    var lines = ["From my Home brief — \(item.kind == .todo ? "to-do" : "item"): \(item.title)"]
    if let reason = item.reason { lines.append("Details: \(reason)") }
    if let source = item.source { lines.append("Source: \(source)") }
    if !item.people.isEmpty { lines.append("People: \(item.people.joined(separator: ", "))") }
    if let time = item.time {
      lines.append("When: \(time.formatted(date: .abbreviated, time: .shortened))")
    }
    if case .openURL(let url) = item.action { lines.append("Link: \(url)") }
    lines.append(
      "Help me action this. Work out what is needed, look it up with the tools you can reach, and propose next steps or a draft. Ask me before sending, replying or changing anything."
    )
    let prompt = lines.joined(separator: "\n")
    let target: HomeConversationTarget = botID.map { .bot($0) } ?? .newSession
    let selectedProvider = provider
    submitting = true
    briefError = nil
    Task {
      do {
        try await submit(target, selectedProvider, prompt)
      } catch {
        briefError = error.localizedDescription
      }
      submitting = false
    }
  }

  private func send() {
    guard let prompt = composedPrompt, !submitting else { return }
    let target = conversationTarget
    let selectedProvider = provider
    submitting = true
    error = nil
    Task {
      do {
        try await submit(target, selectedProvider, prompt)
        draft = ""
        pendingPastes.removeAll()
        pendingImages.removeAll()
      } catch {
        self.error = error.localizedDescription
      }
      submitting = false
    }
  }
}
