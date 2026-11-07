// The checklist widget's window and views. The logic is in Core.swift; see README.md.

import AppKit
import SwiftUI

// MARK: - Views

struct ChecklistView: View {
    let store: NoteStore
    let onHeightChange: (CGFloat) -> Void

    @State private var listHeight: CGFloat = 0

    private var filled: [TaskItem] { store.tasks.filter { !$0.isBlank } }
    private var doneCount: Int { filled.filter(\.done).count }

    /// Tall enough for the screen once the header is counted; beyond that the list scrolls.
    private var maxListHeight: CGFloat {
        (NSScreen.screens.first?.visibleFrame.height ?? 800) - 2 * Config.margin - 130
    }

    /// Headed sections always show; the bit before the first heading only if it has tasks.
    private var visibleSections: [Section] {
        let hasHeadings = store.sections.contains { $0.title != nil }
        return store.sections.filter { section in
            section.title != nil || !hasHeadings || section.tasks.contains { !$0.isBlank }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleSections) { section in
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = section.title {
                                Text(title.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .kerning(0.6)
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.tasks.filter { !$0.isBlank }) { task in
                                TaskRow(task: task, store: store)
                            }
                            AddRow(store: store, sectionID: section.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, maxListHeight))
        }
        .padding(16)
        .frame(width: Config.width, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Config.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.openInObsidian) {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open in Obsidian")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.accentColor)
                        .frame(width: filled.isEmpty ? 0 : geo.size.width * CGFloat(doneCount) / CGFloat(filled.count))
                }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.2), value: doneCount)
        }
    }

    private var title: String {
        guard let date = store.planDate else { return "No note" }
        switch store.mode {
        case .daily:
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .weekly:
            let sunday = NoteDates.calendar.date(byAdding: .day, value: 6, to: date)!
            let format = Date.FormatStyle.dateTime.day().month(.abbreviated)
            return "\(date.formatted(format)) – \(sunday.formatted(format))"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let date = store.planDate {
            // Compare against store.today (not the clock) so this redraws when the day changes.
            switch store.mode {
            case .daily:
                switch NoteDates.calendar.dateComponents([.day], from: store.today, to: date).day {
                case 0: parts.append("Today")
                case 1: parts.append("Tomorrow")
                case -1: parts.append("Yesterday")
                default: break
                }
            case .weekly:
                switch NoteDates.calendar.dateComponents([.day], from: NoteDates.weekStart(store.today), to: date).day {
                case 0: parts.append("This week")
                case 7: parts.append("Next week")
                case -7: parts.append("Last week")
                default: break
                }
            }
        }
        parts.append(filled.isEmpty ? "Nothing planned yet" : "\(doneCount) of \(filled.count) done")
        return parts.joined(separator: " · ")
    }
}

struct AddRow: View {
    let store: NoteStore
    let sectionID: Int

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            TextField("Add a task…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    store.add(text, to: sectionID)
                    text = ""
                    focused = true
                }
        }
        .padding(.vertical, 4)
    }
}

struct TaskRow: View {
    let task: TaskItem
    let store: NoteStore

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(task.done ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            TextField("Task", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .strikethrough(task.done && !focused)
                .foregroundStyle(task.done ? .secondary : .primary)
                .focused($focused)
                .onSubmit { focused = false }

            Button { store.delete(task.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 0.9 : 0.2)
            .help("Delete")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { draft = task.text }
        .onChange(of: task.text) { _, text in if !focused { draft = text } }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && draft != task.text { store.setText(task.id, draft) }
        }
    }
}

// MARK: - Window

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { makeFirstResponder(nil) }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NoteStore(
        mode: CommandLine.arguments.contains("--weekly") ? .weekly : .daily,
        projectDirectory: projectDirectory)  // generated into BuildPaths.swift by build.sh
    private var panel: WidgetPanel!
    private var contentHeight: CGFloat = 240
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: Config.width, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Config.cornerRadius)
        panel.contentView = background

        let hosting = FirstMouseHostingView(rootView: ChecklistView(store: store) { [weak self] height in
            self?.contentHeight = height
            self?.place()
        })
        hosting.sizingOptions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)

        store.isEditing = { [weak self] in self?.panel.firstResponder is NSText }
        store.endEditing = { [weak self] in _ = self?.panel.makeFirstResponder(nil) }
        store.refresh(force: true)

        place()
        panel.orderFrontRegardless()

        // Commit any in-progress edit when focus moves to another app.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.panel.makeFirstResponder(nil) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }

        let timer = Timer(timeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("started")
    }

    /// Middle of the right edge of the primary screen; the weekly widget sits just left of the daily one.
    private func place() {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let height = min(contentHeight, visible.height - 2 * Config.margin)
        let frame = NSRect(
            x: visible.maxX - Config.margin - Config.width - CGFloat(store.mode.slot) * (Config.width + Config.gap),
            y: visible.midY - height / 2,
            width: Config.width, height: height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

@main
enum ChecklistWidgetApp {
    static func main() {
        // Documents is synced with iCloud, which can offload files to save space. Background
        // processes aren't allowed to download them back by default (reads fail with
        // "Resource deadlock avoided"), so opt in.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON)

        trimLogIfHuge()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
