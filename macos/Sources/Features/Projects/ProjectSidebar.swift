import AppKit
import SwiftUI
import Combine

/// Projects group terminal tabs by directory, Teerminal style.
///
/// Every tab is its own `TerminalController` window. Native window tabbing is
/// disabled; instead tabs are grouped into projects by `projectSequence` and only
/// the active tab's window is on screen. All tab windows share one frame, so the
/// app reads as a single window with a project sidebar on the left and a tab
/// strip to its right.
///
/// Projects and tabs keep their creation order. Focus, titles and pwd changes
/// never reorder them so users can rely on where their work lives.
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        let title: String
        weak var window: NSWindow?

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.window === rhs.window
        }
    }

    struct Project: Identifiable, Equatable {
        /// The project's sequence number; stable for the project's lifetime.
        let id: Int
        let directory: URL?
        let tabs: [Tab]

        /// The tab that was last active in this project.
        let selectedTab: Tab?

        /// The window that should be shown when this project is activated.
        var window: NSWindow? { selectedTab?.window ?? tabs.first?.window }

        var name: String {
            guard let directory else { return "Terminal" }
            if directory.path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
            return directory.lastPathComponent
        }

        var abbreviatedPath: String {
            guard let directory else { return "" }
            return (directory.path as NSString).abbreviatingWithTildeInPath
        }

        /// A persistent hue derived from the directory path. Swift's hashValue is
        /// randomized per launch so we use FNV-1a to keep colors stable across restarts.
        var color: Color {
            guard let path = directory?.path else { return .gray }
            var hash: UInt32 = 2166136261
            for byte in path.utf8 {
                hash ^= UInt32(byte)
                hash = hash &* 16777619
            }
            return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.85)
        }
    }

    @Published private(set) var projects: [Project] = []

    private var nextSequence = 1

    /// The frame every tab window shares.
    private var sharedFrame: NSRect?

    /// The last active tab window of each project.
    private var selectedWindows: [Int: Weak<NSWindow>] = [:]

    /// The tab window currently on screen.
    private weak var currentWindow: NSWindow?

    /// Windows that are closing but still listed in NSApp.windows.
    private var closingWindows: Set<ObjectIdentifier> = []

    private var titleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] in self?.windowDidBecomeKey($0.object as? NSWindow) }
            .store(in: &cancellables)
        center.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] in self?.windowWillClose($0.object as? NSWindow) }
            .store(in: &cancellables)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            center.publisher(for: name)
                .sink { [weak self] in self?.windowFrameDidChange($0.object as? NSWindow) }
                .store(in: &cancellables)
        }
    }

    /// Allocates a sequence number for a new project or tab.
    func newSequence() -> Int {
        defer { nextSequence += 1 }
        return nextSequence
    }

    // MARK: Model

    private var controllers: [TerminalController] {
        TerminalController.all.filter {
            guard let window = $0.window else { return false }
            return !closingWindows.contains(ObjectIdentifier(window))
        }
    }

    /// The tab controllers of the project with the given sequence, in tab order.
    func tabControllers(project: Int) -> [TerminalController] {
        controllers
            .filter { $0.projectSequence == project }
            .sorted { $0.tabSequence < $1.tabSequence }
    }

    /// The tab windows of the project containing `window`, in tab order.
    func tabWindows(containing window: NSWindow?) -> [NSWindow] {
        guard let controller = window?.windowController as? TerminalController else { return [] }
        return tabControllers(project: controller.projectSequence).compactMap(\.window)
    }

    /// The last active tab of a project, else its first tab.
    func selectedController(project: Int) -> TerminalController? {
        let tabs = tabControllers(project: project)
        let selected = selectedWindows[project]?.value
        return tabs.first { $0.window === selected } ?? tabs.first
    }

    /// Places a new tab right after `parent` in the parent's project.
    func insertTab(_ controller: TerminalController, after parent: TerminalController) {
        controller.projectSequence = parent.projectSequence
        controller.projectDirectory = parent.projectDirectory

        var tabs = tabControllers(project: parent.projectSequence).filter { $0 !== controller }
        let index = tabs.firstIndex { $0 === parent }.map { $0 + 1 } ?? tabs.count
        tabs.insert(controller, at: index)
        renumber(tabs)
    }

    /// Moves a tab `amount` positions within its project, clamped to the ends.
    func moveTab(_ window: NSWindow, by amount: Int) {
        guard let controller = window.windowController as? TerminalController else { return }
        var tabs = tabControllers(project: controller.projectSequence)
        guard let index = tabs.firstIndex(where: { $0 === controller }) else { return }
        let target = max(0, min(tabs.count - 1, index + amount))
        guard target != index else { return }
        tabs.remove(at: index)
        tabs.insert(controller, at: target)
        renumber(tabs)
        refresh()
    }

    private func renumber(_ tabs: [TerminalController]) {
        for tab in tabs { tab.tabSequence = newSequence() }
    }

    /// Rebuilds the project list from the open terminal windows.
    func refresh() {
        let groups = Dictionary(grouping: controllers, by: \.projectSequence)
        let projects: [Project] = groups.keys.sorted().compactMap { sequence in
            let members = (groups[sequence] ?? []).sorted { $0.tabSequence < $1.tabSequence }
            let tabs: [Tab] = members.compactMap { controller in
                guard let window = controller.window else { return nil }
                observeTitle(of: window)
                return Tab(id: ObjectIdentifier(window), title: window.title, window: window)
            }
            guard !tabs.isEmpty else { return nil }

            let selectedWindow = selectedWindows[sequence]?.value
            let selected = tabs.first { $0.window === selectedWindow }
            return Project(
                id: sequence,
                directory: members.first { $0.projectDirectory != nil }?.projectDirectory,
                tabs: tabs,
                selectedTab: selected ?? tabs.first)
        }

        // Drop observations for windows that are gone.
        let live = Set(projects.flatMap { $0.tabs.map(\.id) })
        titleObservations = titleObservations.filter { live.contains($0.key) }

        if projects != self.projects {
            self.projects = projects
        }
    }

    private func observeTitle(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard titleObservations[id] == nil else { return }
        titleObservations[id] = window.observe(\.title) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    // MARK: Navigation

    /// Shows the given tab window in place of the current one and focuses its terminal.
    func activate(window target: NSWindow?) {
        guard let target else { return }
        if target.isMiniaturized { target.deminiaturize(nil) }
        show(target)
        target.makeKeyAndOrderFront(nil)
        if let controller = target.windowController as? BaseTerminalController,
           let surface = controller.focusedSurface {
            Ghostty.moveFocus(to: surface)
        }
    }

    func activate(_ project: Project) {
        activate(window: project.window)
    }

    /// Moves to the project `delta` rows away from the key window's project, wrapping around.
    @discardableResult
    func activate(offset delta: Int) -> Bool {
        refresh()
        guard projects.count > 1 else { return false }
        let key = (NSApp.keyWindow ?? currentWindow)?.windowController as? TerminalController
        let current = projects.firstIndex { $0.id == key?.projectSequence } ?? 0
        let count = projects.count
        activate(projects[((current + delta) % count + count) % count])
        return true
    }

    /// Asks for a directory and opens it as a new project.
    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else { return }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = url.path
        _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
    }

    /// Opens a new tab in the project of `window`.
    func newTab(in window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalController,
              let surface = controller.focusedSurface?.surface else { return }
        controller.ghostty.newTab(surface: surface)
    }

    // MARK: Window events

    private func isTabWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.windowController is TerminalController else { return false }
        return !closingWindows.contains(ObjectIdentifier(window))
    }

    private func windowDidBecomeKey(_ window: NSWindow?) {
        guard let window, isTabWindow(window) else { return }
        show(window)
    }

    /// Puts a tab window on screen: it takes over the shared frame, becomes its
    /// project's selected tab, and every other tab window leaves the screen.
    func show(_ window: NSWindow) {
        guard let controller = window.windowController as? TerminalController else { return }
        selectedWindows[controller.projectSequence] = .init(window)
        currentWindow = window

        if !window.styleMask.contains(.fullScreen) {
            // Swapping tab windows must be instant: no fade in or out.
            window.animationBehavior = .none
            if let sharedFrame, window.frame != sharedFrame {
                window.setFrame(sharedFrame, display: true)
            }
            sharedFrame = window.frame

            // Put the new tab directly above the one on screen before removing the
            // old one so the desktop never shows through.
            let visible = controllers.compactMap(\.window).filter {
                $0 !== window && $0.isVisible && !$0.styleMask.contains(.fullScreen)
            }
            if let top = visible.first {
                window.order(.above, relativeTo: top.windowNumber)
            } else {
                window.orderFront(nil)
            }
            window.displayIfNeeded()

            for other in visible {
                other.animationBehavior = .none
                other.orderOut(nil)
            }
        }

        refresh()
    }

    private func windowFrameDidChange(_ window: NSWindow?) {
        guard let window, window.isKeyWindow || window === currentWindow, isTabWindow(window),
              !window.styleMask.contains(.fullScreen) else { return }
        sharedFrame = window.frame
    }

    /// When the visible tab closes, show its neighbor: the tab to the right, else the
    /// one to the left, else the next project.
    private func windowWillClose(_ window: NSWindow?) {
        guard let window, isTabWindow(window) else { return }
        let wasVisible = window.isVisible
        let tabs = tabWindows(containing: window)
        closingWindows.insert(ObjectIdentifier(window))

        var successor: NSWindow?
        if let index = tabs.firstIndex(of: window) {
            let rest = tabs.filter { $0 !== window }
            if !rest.isEmpty { successor = rest[min(index, rest.count - 1)] }
        }

        let projectIndex = projects.firstIndex { project in project.tabs.contains { $0.window === window } }
        refresh()

        if successor == nil, let projectIndex, !projects.isEmpty {
            successor = projects[min(projectIndex, projects.count - 1)].window
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.closingWindows.remove(ObjectIdentifier(window))
            if wasVisible { self.activate(window: successor) }
            self.refresh()
        }
    }
}

/// The project list shown on the left of every terminal window. It runs the full
/// window height; the traffic lights sit in its top margin.
struct ProjectSidebarView: View {
    @ObservedObject var store: ProjectStore = .shared

    /// The controller of the window this sidebar lives in; its project is highlighted.
    weak var controller: TerminalController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea()
                .frame(height: ProjectChrome.titlebarHeight)

            HStack {
                Text("Projects")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.openProject()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Open a directory as a new project")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.projects) { project in
                        ProjectRow(project: project, isSelected: project.id == controller?.projectSequence)
                            .onTapGesture { store.activate(project) }
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)

            Text("⌥⌘↑↓ projects  ⌥⌘←→ tabs")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onAppear { store.refresh() }
    }
}

private struct ProjectRow: View {
    let project: ProjectStore.Project
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(project.color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if !project.abbreviatedPath.isEmpty {
                    Text(project.abbreviatedPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            Text("\(project.tabs.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .help(project.tabs.count == 1 ? "1 tab" : "\(project.tabs.count) tabs")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? project.color.opacity(0.25) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(project.color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .help(project.abbreviatedPath)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
