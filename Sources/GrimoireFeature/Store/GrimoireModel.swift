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

    private(set) var cli: CLIStatus = .checking
    private(set) var projects: [ClaudeProject] = []
    private(set) var isLoading = false
    var selectedThreadID: String? {
        didSet { if selectedThreadID != oldValue { loadSelectedThread() } }
    }
    /// The selected thread, ready to draw and talk to. `nil` while it loads.
    private(set) var current: LiveThread?
    private(set) var isLoadingThread = false
    /// Every thread opened this run, by session id — they keep running when
    /// you switch away.
    private(set) var liveThreads: [String: LiveThread] = [:]
    /// The login shell's environment, handed to every agent process.
    private var environment: [String: String] = [:]
    var searchText = ""
    var showsAllProjects = false

    let settings: SettingsStore
    private let sessionsRoot: URL
    private var activation: NSObjectProtocol?

    init(settings: SettingsStore, sessionsRoot: URL = ClaudeSessions.defaultRoot) {
        self.settings = settings
        self.sessionsRoot = sessionsRoot
    }

    /// Starts the first load and the refresh-on-activate observer. Idempotent.
    func start() {
        guard activation == nil else { return }
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        Task { await reload() }
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let root = sessionsRoot
        let (detected, listed) = await Task.detached(priority: .userInitiated) {
            (Self.detectCLI(), ClaudeSessions.projects(root: root))
        }.value
        cli = detected.status
        environment = detected.environment
        projects = Self.merge(listed, openedFolders: settings.openedFolders)
    }

    func openFolder(_ url: URL) {
        settings.addFolder(url.path)
        projects = Self.merge(projects, openedFolders: settings.openedFolders)
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
        Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                ThreadEntries.build((try? ClaudeSessions.history(of: thread.fileURL)) ?? [])
            }.value
            guard selectedThreadID == id else { return }
            let live = LiveThread(
                entries: loaded,
                startOptions: EngineStartOptions(
                    workingDirectory: URL(fileURLWithPath: thread.workingDirectory), resume: thread.id),
                model: thread.model, makeEngine: { [weak self] in self?.makeEngine() ?? UnavailableEngine() })
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

    private func makeEngine() -> HarnessEngine {
        guard case .found(let path, _) = cli else { return UnavailableEngine() }
        return ClaudeEngine(executable: URL(fileURLWithPath: path), environment: environment)
    }

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

    nonisolated static func detectCLI() -> (status: CLIStatus, environment: [String: String]) {
        let environment = CLILocator.loginEnvironment()
        let path = environment["PATH"] ?? ""
        guard let executable = CLILocator.locate("claude", path: path) else {
            return (.missing(searched: path), environment)
        }
        let version = version(of: executable, environment: environment) ?? ""
        return (.found(path: executable.path, version: version), environment)
    }

    /// `claude --version` prints e.g. "2.1.296 (Claude Code)"; the first word is the version.
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
        return String(decoding: output, as: UTF8.self).split(separator: " ").first.map(String.init)
    }
}
