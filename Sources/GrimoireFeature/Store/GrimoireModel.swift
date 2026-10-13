import AinkradAppKit
import AppKit
import Foundation
import Observation

/// Whether the Claude Code CLI is installed, and where.
enum CLIStatus: Equatable, Sendable {
    case checking
    case found(path: String, version: String)
    /// Not on the login shell's PATH; `searched` is that PATH.
    case missing(searched: String)
}

/// The window's state: the CLI, the projects and threads in the sidebar, and
/// the selection. Listing runs off the main thread and refreshes whenever the
/// app becomes active, so a session started in a terminal shows up on return.
@MainActor
@Observable
final class GrimoireModel {
    /// The sidebar lists this many projects until "Show all".
    static let recentLimit = 10

    /// Settable for tests; the app only changes them in `reload()`.
    var cli: CLIStatus = .checking
    /// Codex's, OpenCode's and agy's CLIs, as their listers found them.
    var otherCLIs: [Harness: CLIStatus] = [:]
    /// Found when any agent is: Claude's status unless only another agent is installed.
    var agentStatus: CLIStatus {
        guard case .missing = cli else { return cli }
        return otherCLIs.values.first { if case .found = $0 { true } else { false } } ?? cli
    }

    func status(of harness: Harness) -> CLIStatus {
        harness == .claude ? cli : otherCLIs[harness] ?? .checking
    }
    /// Projects and threads as listed from the CLI's session files.
    private var listed: [ClaudeProject] = []
    /// Threads started here whose session the CLI hasn't written yet.
    private(set) var draftThreads: [ClaudeSessionSummary] = []
    /// What the sidebar lists: the CLI's sessions, new threads on top of
    /// their project, then opened folders with no sessions yet.
    var projects: [ClaudeProject] {
        Self.merge(Self.adding(draftThreads, to: listed), openedFolders: settings.openedFolders)
    }
    private(set) var isLoading = false
    var selectedThreadID: String? {
        didSet {
            guard selectedThreadID != oldValue else { return }
            isShowingSettings = false
            forgeAsk = nil
            loadSelectedThread()
        }
    }
    /// The selected thread, ready to draw and talk to. `nil` while it loads.
    private(set) var current: LiveThread?
    private(set) var isLoadingThread = false
    /// Every thread opened this run, by session id — they keep running when
    /// you switch away.
    private(set) var liveThreads: [String: LiveThread] = [:]
    /// The login shell's environment, handed to every agent process.
    private(set) var environment: [String: String] = [:]
    var searchText = ""
    var showsAllProjects = false
    var isComposingNewThread = false
    /// Bumped by ⌘F and ⌘L; the sidebar search and the composer take focus when they change.
    var searchFocusRequest = 0
    var composerFocusRequest = 0
    /// A request from Forge, waiting in the main pane's inline composer until sent or discarded (see `handleLaunch`).
    var forgeAsk: ForgeAsk?
    /// The review pane beside the conversation; stays open across threads.
    var isReviewOpen = false
    private var reviews: [String: ReviewModel] = [:]

    let settings: SettingsStore
    /// The CLI's rate-limit windows, as last reported by any thread.
    /// Each agent's rate-limit windows: read while listing, then as threads report them.
    var usage: [Harness: [UsageWindow]] = [:]
    /// The clock the limit bar and startup steps read; tests freeze it.
    var now: () -> Date = Date.init
    /// The models each non-Claude agent offers, for the model menus.
    private(set) var models: [Harness: [ModelChoice]] = [:]
    var isShowingSettings = false
    private let signals: PluginSignalEmitter?
    let apps: PluginAppLauncher?
    /// Why the last "open in Rune" didn't happen; cleared on the next try.
    private(set) var terminalProblem: String?
    let sessionsRoot: URL
    typealias Lister = @Sendable ([String: String]) async -> AgentListing
    /// Finds each non-Claude CLI and lists its threads; a harness without one
    /// counts as missing. Tests hand in fixtures.
    var listers: [Harness: Lister] = [:]
    private let openCode = OpenCodeServerBox()

    static func listers(openCode: OpenCodeServerBox) -> [Harness: Lister] {
        [
            .codex: { environment in
                let codex = GrimoireModel.detectCLI(command: "codex", environment: environment).status
                guard case .found(let path, _) = codex else { return AgentListing(status: codex) }
                return CodexSessions.listing(status: codex, executable: URL(fileURLWithPath: path), environment: environment)
            },
            .opencode: { environment in
                let status = GrimoireModel.detectCLI(command: "opencode", environment: environment).status
                guard case .found(let path, _) = status else { return AgentListing(status: status) }
                let server = openCode.server(executable: URL(fileURLWithPath: path), environment: environment)
                let threads = await OpenCodeSessions.summaries(server: server)
                return AgentListing(
                    status: status, threads: threads, models: await OpenCodeSessions.models(server: server, recent: threads))
            },
            .agy: { environment in
                let status = GrimoireModel.detectCLI(command: "agy", environment: environment).status
                guard case .found(let path, _) = status else { return AgentListing(status: status) }
                return AgentListing(
                    status: status, threads: AgySessions.summaries(),
                    models: AgySessions.models(executable: URL(fileURLWithPath: path), environment: environment))
            },
        ]
    }
    private var activation: NSObjectProtocol?

    init(
        settings: SettingsStore, sessionsRoot: URL = ClaudeSessions.defaultRoot, signals: PluginSignalEmitter? = nil,
        apps: PluginAppLauncher? = nil
    ) {
        self.settings = settings
        self.sessionsRoot = sessionsRoot
        // A model on a fixture root is a test: it never runs the real `codex` or `opencode`.
        if sessionsRoot == ClaudeSessions.defaultRoot { listers = Self.listers(openCode: openCode) }
        self.signals = signals
        self.apps = apps
    }

    /// Rune's app id and the launch kind it opens a shell for (see Rune's `RuneLaunch`).
    static let terminalAppID = "rune"
    static let openDirectoryKind = "openDirectory"

    /// Opens Rune with a shell in `thread`'s folder — its worktree, when it has one.
    func openTerminal(for thread: ClaudeSessionSummary) {
        terminalProblem = nil
        guard let apps,
            let payload = AinkradLaunchIntent(kind: Self.openDirectoryKind, path: thread.workingDirectory).json
        else { return }
        guard let reporting = apps as? PluginAppLauncherResult else {
            apps.open(appID: Self.terminalAppID, payload: payload)
            return
        }
        switch reporting.openReportingOutcome(appID: Self.terminalAppID, payload: payload) {
        case .opened: break
        case .unknownApp: terminalProblem = "Install Rune from the Ainkrad store to open a terminal here."
        case .disabled: terminalProblem = "Rune is turned off — enable it in Ainkrad to open a terminal here."
        case .refused(let reason): terminalProblem = "Rune didn't open: \(reason)"
        @unknown default: terminalProblem = "Rune didn't open."
        }
    }

    /// Starts the refresh-on-activate observer, and the first load unless one
    /// already happened. Idempotent.
    func start() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        if cli == .checking { Task { await reload() } }
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let root = sessionsRoot
        let override = settings.cliPathOverride
        let listers = listers
        let opened = Set(settings.openedFolders)
        let (detected, listings, listed) = await Task.detached(priority: .userInitiated) {
            let detected = Self.detectCLI(override: override)
            var listings: [Harness: AgentListing] = [:]
            var threads = ClaudeSessions.projects(root: root).flatMap(\.sessions)
            for harness in Harness.allCases where harness != .claude {
                let listing = await listers[harness]?(detected.environment) ?? AgentListing(status: .missing(searched: ""))
                listings[harness] = listing
                threads += listing.threads
            }
            return (detected, listings, ClaudeSessions.grouped(ClaudeSessions.withoutScratch(threads, keeping: opened)))
        }.value
        cli = detected.status
        otherCLIs = listings.mapValues(\.status)
        models = listings.mapValues(\.models)
        for (harness, listing) in listings where !listing.usage.isEmpty { usage[harness] = listing.usage }
        environment = detected.environment
        self.listed = listed
        // A draft is done once its session shows up in the listing.
        let known = Set(listed.flatMap(\.sessions).map(\.id))
        draftThreads.removeAll { known.contains($0.id) }
    }

    func openFolder(_ url: URL) {
        settings.addFolder(url.path)
    }

    /// Starts a new thread in `project` and opens it. It shows at once as a
    /// draft; when the CLI names the session the draft takes that id.
    func startThread(
        project: String, prompt: String, model: String?, mode: PermissionMode, worktree: Bool,
        harness: Harness = .claude
    ) {
        let placeholder = "new-\(UUID().uuidString)"
        // Only Claude Code has a worktree flag.
        let worktreeName = worktree && harness == .claude ? Self.worktreeName(for: prompt) : nil
        let draft = ClaudeSessionSummary(
            id: placeholder, harness: harness, fileURL: URL(fileURLWithPath: "/dev/null"), workingDirectory: project,
            projectPath: project, worktree: worktreeName, title: ClaudeSessionSummary.title(prompt), model: model,
            lastActivity: Date())
        let live = makeLive(
            harness: harness,
            entries: [],
            options: EngineStartOptions(
                workingDirectory: URL(fileURLWithPath: project), model: model, permissionMode: mode,
                worktree: worktreeName),
            model: model)
        live.onSessionID = { [weak self] id in self?.adopt(placeholder, as: id) }
        draftThreads.insert(draft, at: 0)
        liveThreads[placeholder] = live
        selectedThreadID = placeholder
        live.send(prompt)
    }

    /// Continues `thread` as a new session with the same history. The fork
    /// shows as a draft until its first message, when the CLI names it.
    func forkThread(_ thread: ClaudeSessionSummary) {
        guard let source = liveThreads[thread.id] else { return }
        let placeholder = "new-\(UUID().uuidString)"
        let draft = ClaudeSessionSummary(
            id: placeholder, harness: thread.harness, fileURL: URL(fileURLWithPath: "/dev/null"),
            workingDirectory: thread.workingDirectory,
            projectPath: thread.projectPath, worktree: thread.worktree, title: "Fork of \(thread.title)",
            gitBranch: thread.gitBranch, model: source.model, lastActivity: Date())
        let live = makeLive(
            harness: thread.harness,
            entries: source.entries,
            options: EngineStartOptions(
                workingDirectory: URL(fileURLWithPath: thread.workingDirectory), resume: thread.id, fork: true),
            model: source.model)
        live.onSessionID = { [weak self] id in self?.adopt(placeholder, as: id) }
        draftThreads.insert(draft, at: 0)
        liveThreads[placeholder] = live
        selectedThreadID = placeholder
    }

    /// Re-keys a new thread under the session id the CLI gave it.
    private func adopt(_ placeholder: String, as id: String) {
        guard let live = liveThreads.removeValue(forKey: placeholder) else { return }
        liveThreads[id] = live
        if let index = draftThreads.firstIndex(where: { $0.id == placeholder }) { draftThreads[index].id = id }
        if selectedThreadID == placeholder { selectedThreadID = id }
        Task { await reload() }
    }

    /// `fix the login bug` → `fix-the-login-bug-3f2a`: a branch-safe worktree name.
    static func worktreeName(for prompt: String, suffix: String = String(UUID().uuidString.prefix(4)).lowercased())
        -> String
    {
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(5)
        let slug = words.joined(separator: "-")
        return (slug.isEmpty ? "thread" : String(slug.prefix(40))) + "-" + suffix
    }

    static func adding(_ drafts: [ClaudeSessionSummary], to projects: [ClaudeProject]) -> [ClaudeProject] {
        guard !drafts.isEmpty else { return projects }
        var projects = projects
        for draft in drafts.reversed() {
            if let index = projects.firstIndex(where: { $0.path == draft.projectPath }) {
                projects[index].sessions.removeAll { $0.id == draft.id }
                projects[index].sessions.insert(draft, at: 0)
            } else {
                projects.insert(ClaudeProject(path: draft.projectPath, sessions: [draft]), at: 0)
            }
        }
        return projects
    }

    /// Opens the selected thread: the live one if it was opened before, else
    /// its session file read off the main thread. A slower load for an earlier
    /// selection never overwrites a newer one.
    private func loadSelectedThread() {
        guard let thread = selectedThread else {
            current = nil
            return
        }
        if let live = liveThreads[thread.id] {
            current = live
            return
        }
        current = nil
        let id = thread.id
        isLoadingThread = true
        let status = status(of: thread.harness)
        let environment = environment
        let openCode = openCode.current
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> [ThreadEntry] in
                switch (thread.harness, status) {
                case (.claude, _): ThreadEntries.build((try? ClaudeSessions.history(of: thread.fileURL)) ?? [])
                case (.codex, .found(let path, _)):
                    ThreadEntries.build(
                        CodexSessions.history(
                            threadID: thread.id, executable: URL(fileURLWithPath: path), environment: environment))
                case (.opencode, .found):
                    if let openCode { ThreadEntries.build(await OpenCodeSessions.history(of: thread, server: openCode)) }
                    else { [] }
                // agy stores earlier turns in an internal format; only new ones show.
                case (.agy, _): [.text(Self.agyHistoryNote)]
                case (.codex, _), (.opencode, _): []
                }
            }.value
            guard selectedThreadID == id else { return }
            let live = makeLive(
                harness: thread.harness,
                entries: loaded,
                options: EngineStartOptions(
                    workingDirectory: URL(fileURLWithPath: thread.workingDirectory), resume: thread.id),
                model: thread.model)
            liveThreads[id] = live
            current = live
            isLoadingThread = false
        }
    }

    /// Files under `directory` for `@` suggestions. Returns what is known now
    /// and lists the folder in the background the first time it's asked for.
    private var projectFiles: [String: [String]] = [:]
    func files(in directory: String) -> [String] {
        if let files = projectFiles[directory] { return files }
        projectFiles[directory] = []
        Task {
            let listed = await Task.detached(priority: .utility) {
                ProjectFiles.list(root: URL(fileURLWithPath: directory))
            }.value
            projectFiles[directory] = listed
        }
        return []
    }

    /// The selected thread's review state, kept per thread.
    func review(for thread: ClaudeSessionSummary) -> ReviewModel? {
        guard let live = current else { return nil }
        if let review = reviews[thread.id] { return review }
        let review = ReviewModel(live: live, workingDirectory: thread.workingDirectory, environment: environment)
        reviews[thread.id] = review
        return review
    }

    /// Every thread is made here, so each one reports usage and approvals.
    private func makeLive(harness: Harness, entries: [ThreadEntry], options: EngineStartOptions, model: String?)
        -> LiveThread
    {
        let live = LiveThread(
            entries: entries, startOptions: options, model: model, clock: { [weak self] in self?.now() ?? Date() },
            makeEngine: { [weak self] in self?.makeEngine(harness) ?? UnavailableEngine() })
        live.agentName = harness.displayName
        live.onUsage = { [weak self] windows in self?.usage[harness] = windows }
        live.onUsageLimit = { [weak self] hint in self?.markLimited(harness, resetHint: hint) }
        live.onNeedsYou = { [weak self, weak live] request in
            guard let self, let live else { return }
            self.notifyNeedsYou(live, request: request)
        }
        live.onTurnFinished = { [weak self, weak live] started in
            guard let self, let live else { return }
            self.announceTurn(live, harness: harness, startedAt: started)
        }
        return live
    }

    /// An urgent Signal when a thread you aren't looking at waits on you.
    private func notifyNeedsYou(_ live: LiveThread, request: ApprovalRequest) {
        guard settings.notifyWhenNeeded, let signals else { return }
        let key = liveThreads.first { $0.value === live }?.key
        let thread = key.flatMap { key in projects.lazy.flatMap(\.sessions).first { $0.id == key } }
        guard key != selectedThreadID || !NSApplication.shared.isActive else { return }
        signals.emit(
            kind: "grimoire.needs-you", severity: .warning,
            title: "Grimoire needs you\(thread.map { " in \($0.title)" } ?? "")",
            body:
                "\(request.toolName) \(ToolSummary.argument(name: request.toolName, input: request.input, workingDirectory: thread?.workingDirectory ?? ""))",
            importance: .urgent, dedupeKey: "grimoire.needs-you:\(request.id)")
    }

    /// Tests hand in a fake; the app always uses the CLI it found.
    var engineOverride: (() -> HarnessEngine)?

    private func makeEngine(_ harness: Harness) -> HarnessEngine {
        if let engineOverride { return engineOverride() }
        guard case .found(let path, _) = status(of: harness) else { return UnavailableEngine() }
        let executable = URL(fileURLWithPath: path)
        switch harness {
        case .claude: return ClaudeEngine(executable: executable, environment: environment)
        case .codex: return CodexEngine(executable: executable, environment: environment)
        case .opencode:
            return OpenCodeEngine(server: openCode.server(executable: executable, environment: environment))
        case .agy: return AgyEngine(executable: executable, environment: environment)
        }
    }

    nonisolated static let agyHistoryNote =
        "*agy keeps this conversation's earlier turns in its own format, so they aren't shown here. New turns appear below.*"

    // MARK: - What the sidebar shows

    /// Projects filtered by the search text (title match on any thread, or the
    /// project's name), then cut to the most recent unless "Show all".
    var visibleProjects: [ClaudeProject] {
        let filtered = Self.filter(projects, query: searchText)
        guard searchText.isEmpty, !showsAllProjects else { return filtered }
        return Array(filtered.prefix(Self.recentLimit))
    }

    /// How many projects "Show all" would add.
    var hiddenProjectCount: Int {
        searchText.isEmpty && !showsAllProjects ? max(projects.count - Self.recentLimit, 0) : 0
    }

    var mostRecentProject: String? { projects.first?.path }

    /// `id`'s menu name for `harness`: its listed name, else a tidied id.
    func modelName(_ id: String?, for harness: Harness) -> String {
        guard let id else { return "Default" }
        return models[harness]?.first { $0.id == id }?.name ?? ModelName.display(id)
    }

    var selectedThread: ClaudeSessionSummary? {
        guard let id = selectedThreadID else { return nil }
        return projects.lazy.flatMap(\.sessions).first { $0.id == id }
    }

    // MARK: - Pure helpers

    static func filter(_ projects: [ClaudeProject], query: String) -> [ClaudeProject] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.compactMap { project in
            if project.name.localizedCaseInsensitiveContains(query) { return project }
            let sessions = project.sessions.filter { $0.title.localizedCaseInsensitiveContains(query) }
            return sessions.isEmpty ? nil : ClaudeProject(path: project.path, sessions: sessions)
        }
    }

    /// Opened folders that have no sessions yet are listed after the rest.
    static func merge(_ projects: [ClaudeProject], openedFolders: [String]) -> [ClaudeProject] {
        let known = Set(projects.map(\.path))
        return projects + openedFolders.filter { !known.contains($0) }.map { ClaudeProject(path: $0, sessions: []) }
    }

    nonisolated static func detectCLI(override: String? = nil) -> (status: CLIStatus, environment: [String: String]) {
        let environment = CLILocator.loginEnvironment()
        let path = environment["PATH"] ?? ""
        let chosen = override.flatMap { CLILocator.defaultIsExecutable($0) ? URL(fileURLWithPath: $0) : nil }
        guard let executable = chosen ?? CLILocator.locate("claude", path: path) else {
            return (.missing(searched: path), environment)
        }
        let version = version(of: executable, environment: environment) ?? ""
        return (.found(path: executable.path, version: version), environment)
    }

    nonisolated static func detectCLI(command: String, environment: [String: String]) -> (
        status: CLIStatus, environment: [String: String]
    ) {
        let path = environment["PATH"] ?? ""
        guard let executable = CLILocator.locate(command, path: path) else { return (.missing(searched: path), environment) }
        return (.found(path: executable.path, version: version(of: executable, environment: environment) ?? ""), environment)
    }

    /// `claude --version` prints "2.1.296 (Claude Code)", `codex --version`
    /// "codex-cli 0.154.0"; the version is the first word starting with a digit.
    nonisolated static func version(of executable: URL, environment: [String: String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            .first { $0.first?.isNumber == true }.map(String.init)
    }
}

