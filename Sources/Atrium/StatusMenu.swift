import AppKit
import AtriumCore
import Carbon.HIToolbox

/// The menu bar icon and its menu: the whole user interface.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var clock: Timer?
    private var hotKey: GlobalHotKey?

    /// ⌃⌥⌘R: unlikely to clash with any app's own shortcut.
    static let shortcutLabel = "⌃⌥⌘R"

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Atrium — record a call (\(Self.shortcutLabel))"
        hotKey = GlobalHotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            Task { @MainActor in self?.controller.toggle() }
        }
        controller.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        guard let button = item.button else { return }
        let symbol: String
        switch controller.recording {
        case .recording(_, let since):
            symbol = "record.circle.fill"
            button.contentTintColor = .systemRed
            button.title = " " + Self.elapsed(since: since)
            if clock == nil {
                clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
            }
        case .idle, .starting:
            symbol = controller.transcribing != nil ? "text.bubble" : "waveform"
            button.contentTintColor = nil
            button.title = ""
            clock?.invalidate()
            clock = nil
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Atrium")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        if isMenuOpen { rebuild() }
    }

    private var isMenuOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        rebuild()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func rebuild() {
        menu.removeAllItems()

        switch controller.recording {
        case .idle:
            add("Start Recording", showsShortcut: true, action: #selector(toggleRecording))
        case .starting:
            add("Starting…", enabled: false)
        case .recording(_, let since):
            add("Recording — \(Self.elapsed(since: since))", enabled: false)
            add("Stop and Transcribe", showsShortcut: true, action: #selector(toggleRecording))
        }

        if let folder = controller.transcribing {
            let percent = Int(controller.transcriptionProgress * 100)
            add("Transcribing \(Self.name(of: folder))… \(percent)%", enabled: false)
            if !controller.queued.isEmpty {
                add("\(controller.queued.count) more waiting", enabled: false)
            }
        }

        menu.addItem(.separator())
        let sessions = Array(SessionStore.sessions().prefix(8))
        if sessions.isEmpty {
            add("No calls yet", enabled: false)
        } else {
            add("Recent Calls", enabled: false)
            for session in sessions { addSession(session) }
        }

        menu.addItem(.separator())
        add("Open Recordings Folder", action: #selector(openFolder))
        add("Quit Atrium", action: #selector(quit))
    }

    private func addSession(_ session: Session) {
        let name = Self.name(of: session.folder)
        let busy = controller.transcribing == session.folder || controller.queued.contains(session.folder)
        let entry: NSMenuItem
        switch session.state {
        case .transcribed:
            entry = add(name, action: #selector(openTranscript(_:)))
        case .untranscribed where busy:
            entry = add("\(name) — transcribing", enabled: false)
        case .untranscribed(let error):
            entry = add("\(name) — not transcribed. Transcribe now", action: #selector(transcribe(_:)))
            entry.toolTip = error
            entry.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
        entry.representedObject = session.folder
        entry.indentationLevel = 1
    }

    @discardableResult
    private func add(_ title: String, showsShortcut: Bool = false, action: Selector? = nil,
                     enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: showsShortcut ? "r" : "")
        if showsShortcut { entry.keyEquivalentModifierMask = [.control, .option, .command] }
        entry.target = self
        entry.isEnabled = enabled && action != nil
        menu.addItem(entry)
        return entry
    }

    @objc private func toggleRecording() { controller.toggle() }

    @objc private func openTranscript(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(SessionFiles.transcript(in: folder))
    }

    @objc private func transcribe(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        controller.enqueue(folder)
    }

    @objc private func openFolder() {
        let root = SessionStore.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func quit() {
        if controller.isRecording || controller.transcribing != nil {
            let alert = NSAlert()
            alert.messageText = controller.isRecording ? "A call is being recorded" : "A call is being transcribed"
            alert.informativeText = controller.isRecording
                ? "Quitting stops the recording. It will be transcribed next time Atrium opens."
                : "It will finish next time Atrium opens."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if controller.isRecording { controller.stop() }
        }
        NSApp.terminate(nil)
    }

    static func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "Pricing review · Today 15:17"; "Yesterday 09:02" before a call is named.
    static func name(of folder: URL) -> String {
        guard let session = SessionStore.session(at: folder) else { return folder.lastPathComponent }
        let date = session.createdAt
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        let when = calendar.isDateInToday(date) ? "Today \(time)"
            : calendar.isDateInYesterday(date) ? "Yesterday \(time)"
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return session.title.map { "\($0) · \(when)" } ?? when
    }
}
