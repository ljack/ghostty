import AppKit
import SwiftUI

/// Layout constants for the project sidebar and tab strip.
enum ProjectChrome {
    /// Height of the tab strip; it occupies the titlebar area right of the sidebar.
    static let titlebarHeight: CGFloat = 38
    static let sidebarWidth: CGFloat = 210
    static let maxTabWidth: CGFloat = 240
    static let minTabWidth: CGFloat = 90
}

/// The window content: a full-height project sidebar, and to its right the
/// project's tab strip above the terminal.
struct ProjectWindowView<Content: View>: View {
    weak var controller: TerminalController?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            ProjectSidebarView(controller: controller)
                .frame(width: ProjectChrome.sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                ProjectTabBar(controller: controller)
                    .frame(height: ProjectChrome.titlebarHeight)
                Divider()
                content()
            }
        }
        // The sidebar and tab strip extend into the transparent titlebar.
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The tabs of one project. It is shown even when the project has a single tab
/// so the tab row stays a fixed landmark.
struct ProjectTabBar: View {
    @ObservedObject var store: ProjectStore = .shared
    weak var controller: TerminalController?

    private var project: ProjectStore.Project? {
        guard let controller else { return nil }
        return store.projects.first { $0.id == controller.projectSequence }
    }

    var body: some View {
        HStack(spacing: 0) {
            if let project {
                ForEach(project.tabs) { tab in
                    ProjectTabView(
                        tab: tab,
                        color: project.color,
                        isSelected: tab.window === controller?.window,
                        canClose: true)
                }
            }

            Button {
                store.newTab(in: controller?.window)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Tab")
            .padding(.horizontal, 4)

            WindowDragArea()
        }
        .padding(.top, 4)
        .background(WindowDragArea())
    }
}

private struct ProjectTabView: View {
    @ObservedObject var store: ProjectStore = .shared
    let tab: ProjectStore.Tab
    let color: Color
    let isSelected: Bool
    let canClose: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title.isEmpty ? "Terminal" : tab.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                (tab.window?.windowController as? TerminalController)?.closeTab(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(isSelected || isHovering ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: ProjectChrome.minTabWidth, maxWidth: ProjectChrome.maxTabWidth, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.primary.opacity(0.10) : isHovering ? Color.primary.opacity(0.05) : .clear)
                .padding(.bottom, 4)
        )
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle()
                    .fill(color)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .overlay(alignment: .trailing) {
            if !isSelected {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
                    .padding(.vertical, 8)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { store.activate(window: tab.window) }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Empty chrome that moves the window when dragged and zooms it on double-click,
/// like a titlebar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
