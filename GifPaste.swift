// GifPaste — minimal standalone GIPHY search that pastes the GIF into the app you were typing in.
// Simplified from the Raycast "GIF Search" extension (MIT): GIPHY only, search + trending, paste/copy.
//
// Build: ./build.sh   (needs Xcode Command Line Tools: xcode-select --install)

import Carbon
import Cocoa
import Security
import ServiceManagement

// MARK: - Settings

enum Config {
    static let rating = "g"   // g, pg, pg-13, r
    static let lang = "en"
    static let limit = 24
    static let columns = 4
}

// MARK: - Shortcut (stored in UserDefaults, changeable from the menu bar)

struct HotKey {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var label: String

    static let `default` = HotKey(keyCode: UInt32(kVK_ANSI_G), carbonModifiers: UInt32(controlKey | optionKey), label: "⌃⌥G")

    static func load() -> HotKey {
        let d = UserDefaults.standard
        guard let label = d.string(forKey: "hotKeyLabel") else { return .default }
        return HotKey(
            keyCode: UInt32(d.integer(forKey: "hotKeyCode")),
            carbonModifiers: UInt32(d.integer(forKey: "hotKeyModifiers")),
            label: label)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "hotKeyCode")
        d.set(Int(carbonModifiers), forKey: "hotKeyModifiers")
        d.set(label, forKey: "hotKeyLabel")
    }

    /// Builds a shortcut from a key press. Returns nil unless ⌘, ⌃ or ⌥ is held.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var mods: UInt32 = 0
        var label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods, label: label + HotKey.keyName(event))
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.label = label
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↵"
        case kVK_Tab: return "⇥"
        default: break
        }
        let fKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = fKeys[Int(event.keyCode)] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "#\(event.keyCode)"
    }
}

// MARK: - API key storage (login Keychain, item "GifPaste" / "giphy-api-key")

enum APIKeyStore {
    private static let service = "GifPaste"
    private static let account = "giphy-api-key"
    private static var cached: String?

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["GIPHY_API_KEY"], !env.isEmpty { return env }
        if let cached { return cached }

        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        cached = key
        return key
    }

    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "GifPaste GIPHY API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain error \(status)"])
        }
        cached = key
    }
}

// MARK: - GIPHY API

struct GiphyResponse: Decodable { let data: [GiphyGif] }

struct GiphyGif: Decodable {
    struct Rendition: Decodable { let url: String? }
    struct Images: Decodable {
        let original: Rendition?
        let fixed_width_small: Rendition?
        let fixed_width: Rendition?
        let preview_gif: Rendition?
        let downsized: Rendition?
    }

    let id: String
    let title: String?
    let slug: String?
    let images: Images

    var previewURL: URL? {
        [images.fixed_width_small?.url, images.fixed_width?.url, images.preview_gif?.url, images.original?.url]
            .compactMap { $0 }.first.flatMap { URL(string: $0) }
    }

    var originalURL: URL? { images.original?.url.flatMap { URL(string: $0) } }

    /// Bigger, still lightweight rendition for the preview pane (GIPHY "downsized" is < 2 MB).
    var largePreviewURL: URL? {
        [images.downsized?.url, images.fixed_width?.url, images.original?.url]
            .compactMap { $0 }.first.flatMap { URL(string: $0) }
    }

    /// File name shown by Slack/Teams etc. next to the pasted GIF.
    /// Uses the search term ("thumbs up.gif"); falls back to the GIPHY title for trending GIFs.
    func fileName(searchTerm: String?, withExtension: Bool) -> String {
        let term = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = !term.isEmpty ? term : (title?.isEmpty == false ? title! : (slug ?? id))
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return (cleaned.isEmpty ? id : String(cleaned.prefix(80))) + (withExtension ? ".gif" : "")
    }
}

enum GifError: LocalizedError {
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .http(let code) where code == 401 || code == 403: return "GIPHY rejected the API key (HTTP \(code))"
        case .http(429): return "GIPHY rate limit reached (HTTP 429)"
        case .http(let code): return "GIPHY error (HTTP \(code))"
        }
    }
}

enum Giphy {
    static func fetch(query: String, apiKey: String) async throws -> [GiphyGif] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var comps = URLComponents(
            string: q.isEmpty ? "https://api.giphy.com/v1/gifs/trending" : "https://api.giphy.com/v1/gifs/search")!
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(Config.limit)),
            URLQueryItem(name: "rating", value: Config.rating),
        ]
        if !q.isEmpty {
            items += [URLQueryItem(name: "q", value: q), URLQueryItem(name: "lang", value: Config.lang)]
        }
        comps.queryItems = items
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        try check(response)
        return try JSONDecoder().decode(GiphyResponse.self, from: data).data
    }

    static func download(_ url: URL, name: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GifPaste", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // One subfolder per download so the same search term twice never overwrites a file still being pasted.
        let folder = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(name)
        try data.write(to: dest, options: .atomic)
        return dest
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw GifError.http(http.statusCode) }
    }
}

// MARK: - Views

final class SearchPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class GifCell: NSImageView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelectedCell = false {
        didSet { layer?.borderWidth = isSelectedCell ? 3 : 0 }
    }
    private var trackingArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { onHover?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }
}

// MARK: - App

@MainActor var sharedDelegate: AppDelegate?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSSearchFieldDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: SearchPanel!
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let gridView = FlippedView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var hotKeyRef: EventHotKeyRef?
    private var hotKey = HotKey.load()
    private var searchMenuItem: NSMenuItem!
    private var extensionMenuItem: NSMenuItem!
    private var launchMenuItem: NSMenuItem?
    /// When false, the pasted file is named "thumbs up" instead of "thumbs up.gif".
    private var includeGifExtension: Bool {
        get { UserDefaults.standard.object(forKey: "includeGifExtension") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "includeGifExtension") }
    }

    private var previousApp: NSRunningApplication?
    private var gifs: [GiphyGif] = []
    private var cells: [GifCell] = []
    private var selectedIndex = 0
    private var lastQuery: String?
    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var isPasting = false
    private let previewCache = NSCache<NSURL, NSImage>()
    private let largePreviewCache = NSCache<NSURL, NSImage>()
    private let previewView = NSImageView()
    private let previewTitle = NSTextField(labelWithString: "")
    private var previewToken = 0
    /// Mouse position at the last hover/keyboard move. Hover only changes the selection when the
    /// mouse really moved, so cells scrolling under a resting cursor don't steal keyboard selection.
    private var lastPointer: NSPoint?

    private let helpText = "↑↓←→ select · ↵ paste · ⌘↵ copy only · esc close — Powered by GIPHY"

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedDelegate = self
        setupMainMenu()
        setupStatusItem()
        setupPanel()
        registerHotKey()

        // Needed to send ⌘V to the other app. Without it, the GIF is only copied.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if APIKeyStore.load() == nil { promptForAPIKey() }
    }

    // MARK: Setup

    /// Menu-bar-only apps have no main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z would do nothing in text fields.
    /// This invisible Edit menu routes those shortcuts to the focused field.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = Bundle.main.image(forResource: "MenuBarIcon") {
            image.isTemplate = true // macOS tints it for light/dark menu bars
            image.size = NSSize(width: 30, height: 18)
            image.accessibilityDescription = "GifPaste"
            statusItem.button?.image = image
        } else if let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "GifPaste") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "GIF"
        }
        let menu = NSMenu()
        searchMenuItem = menu.addItem(withTitle: "", action: #selector(togglePanel), keyEquivalent: "")
        searchMenuItem.target = self
        extensionMenuItem = menu.addItem(
            withTitle: "Add .gif to File Name", action: #selector(toggleGifExtension), keyEquivalent: "")
        extensionMenuItem.target = self
        extensionMenuItem.state = includeGifExtension ? .on : .off
        menu.addItem(withTitle: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Set GIPHY API Key…", action: #selector(promptForAPIKey), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GifPaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if #available(macOS 13, *) {
            let item = menu.insertItem(
                withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "",
                at: menu.items.count - 2) // above the separator before Quit
            item.target = self
            launchMenuItem = item
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    private func setupPanel() {
        let size = NSSize(width: 920, height: 460)
        let gridWidth: CGFloat = 604
        panel = SearchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hidePanel(restoreFocus: true) }

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        searchField.frame = NSRect(x: 16, y: 396, width: size.width - 32, height: 30)
        searchField.font = .systemFont(ofSize: 17)
        searchField.placeholderString = "Search GIPHY…"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        background.addSubview(searchField)

        scrollView.frame = NSRect(x: 8, y: 34, width: gridWidth, height: 354)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = gridView
        background.addSubview(scrollView)

        // Preview pane: bigger animated version of the selected/hovered GIF
        let previewX = 8 + gridWidth + 8
        let previewWidth = size.width - previewX - 16
        largePreviewCache.countLimit = 40
        previewView.frame = NSRect(x: previewX, y: 66, width: previewWidth, height: 314)
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 8
        previewView.layer?.masksToBounds = true
        previewView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.animates = true
        previewView.isEditable = false
        background.addSubview(previewView)

        previewTitle.frame = NSRect(x: previewX, y: 38, width: previewWidth, height: 20)
        previewTitle.font = .systemFont(ofSize: 12, weight: .medium)
        previewTitle.textColor = .secondaryLabelColor
        previewTitle.lineBreakMode = .byTruncatingTail
        previewTitle.alignment = .center
        background.addSubview(previewTitle)

        statusLabel.frame = NSRect(x: 16, y: 10, width: size.width - 32, height: 18)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = helpText
        background.addSubview(statusLabel)
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in sharedDelegate?.togglePanel() }
            return noErr
        }, 1, &spec, nil, nil)

        if !apply(hotKey) {
            showAlert("Could not register \(hotKey.label)",
                      "Another app uses this shortcut. Pick a different one via the menu bar icon → Change Shortcut….")
        }
    }

    /// Registers `key` as the global shortcut, replacing the current one. Returns false if macOS refused it.
    @discardableResult
    private func apply(_ key: HotKey) -> Bool {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let id = EventHotKeyID(signature: OSType(0x4749_4650), id: 1) // "GIFP"
        let status = RegisterEventHotKey(
            key.keyCode, key.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        searchMenuItem.title = "Search GIFs  \(key.label)"
        return status == noErr
    }

    // MARK: Launch at login (macOS 13+, SMAppService)

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh in case it was changed in System Settings → Login Items.
        guard #available(macOS 13, *) else { return }
        launchMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleLaunchAtLogin() {
        guard #available(macOS 13, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert("Could not change Launch at Login", error.localizedDescription)
        }
        if service.status == .requiresApproval {
            showAlert("Approval needed", "Allow GifPaste in System Settings → General → Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
        launchMenuItem?.state = service.status == .enabled ? .on : .off
    }

    @objc func toggleGifExtension() {
        includeGifExtension.toggle()
        extensionMenuItem.state = includeGifExtension ? .on : .off
    }

    @objc func changeShortcut() {
        let alert = NSAlert()
        alert.messageText = "Press the new shortcut"
        alert.informativeText = "Current: \(hotKey.label)\nUse ⌘, ⌃ or ⌥ plus a key."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset to \(HotKey.default.label)")

        // Suspend the current shortcut so pressing it again can be recorded.
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }

        var recorded: HotKey?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { NSApp.stopModal(withCode: .alertFirstButtonReturn); return nil }
            guard let key = HotKey(event: event) else { NSSound.beep(); return nil }
            recorded = key
            NSApp.stopModal(withCode: .OK)
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }

        let previous = hotKey
        let candidate: HotKey?
        switch response {
        case .OK: candidate = recorded
        case .alertSecondButtonReturn: candidate = .default
        default: candidate = nil
        }

        guard let candidate else { apply(previous); return }
        if apply(candidate) {
            hotKey = candidate
            candidate.save()
        } else {
            apply(previous)
            showAlert("\(candidate.label) is not available", "Another app already uses it. Kept \(previous.label).")
        }
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Show / hide

    @objc func togglePanel() {
        panel.isVisible ? hidePanel(restoreFocus: true) : showPanel()
    }

    private func showPanel() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }

        let mouse = NSEvent.mouseLocation
        if let frame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2 + frame.height * 0.1))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
        if gifs.isEmpty { scheduleSearch(delay: 0) }
    }

    private func hidePanel(restoreFocus: Bool) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        guard restoreFocus else { return }
        if let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        } else {
            NSApp.hide(nil)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isPasting { hidePanel(restoreFocus: false) }
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) { scheduleSearch(delay: 0.3) }

    @objc private func searchFieldAction() { scheduleSearch(delay: 0.3) }

    private func scheduleSearch(delay: Double) {
        searchTask?.cancel()
        let query = searchField.stringValue
        searchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            await self.runSearch(query)
        }
    }

    private func runSearch(_ query: String) async {
        guard let key = APIKeyStore.load() else {
            setStatus("No GIPHY API key. Set it via the menu bar icon.")
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        setStatus(query.isEmpty ? "Loading trending…" : "Searching…")
        do {
            let results = try await Giphy.fetch(query: query, apiKey: key)
            guard generation == searchGeneration else { return }
            gifs = results
            lastQuery = query
            layoutGrid()
            setStatus(results.isEmpty ? "No results" : helpText)
        } catch {
            guard generation == searchGeneration else { return }
            if (error as? URLError)?.code == .cancelled { return }
            setStatus("Error: \(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) { statusLabel.stringValue = text }

    // MARK: Grid

    private func layoutGrid() {
        cells.forEach { $0.removeFromSuperview() }
        cells = []

        let columns = Config.columns
        let spacing: CGFloat = 8
        let width = scrollView.contentSize.width
        let cellWidth = floor((width - spacing * CGFloat(columns + 1)) / CGFloat(columns))
        let cellHeight = floor(cellWidth * 0.75)
        let rows = (gifs.count + columns - 1) / columns
        let height = max(scrollView.contentSize.height, spacing + CGFloat(rows) * (cellHeight + spacing))
        gridView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        for (index, gif) in gifs.enumerated() {
            let frame = NSRect(
                x: spacing + CGFloat(index % columns) * (cellWidth + spacing),
                y: spacing + CGFloat(index / columns) * (cellHeight + spacing),
                width: cellWidth, height: cellHeight)
            let cell = GifCell(frame: frame)
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 6
            cell.layer?.masksToBounds = true
            cell.layer?.borderColor = NSColor.controlAccentColor.cgColor
            cell.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            cell.imageScaling = .scaleProportionallyUpOrDown
            cell.animates = true
            cell.isEditable = false
            cell.toolTip = gif.title
            cell.onClick = { [weak self] in
                self?.select(index)
                self?.pasteSelected(copyOnly: false)
            }
            cell.onHover = { [weak self] in
                guard let self else { return }
                let pointer = NSEvent.mouseLocation
                defer { self.lastPointer = pointer }
                guard pointer != self.lastPointer, index != self.selectedIndex else { return }
                self.select(index, scroll: false)
            }
            gridView.addSubview(cell)
            cells.append(cell)
            loadPreview(gif, into: cell, generation: searchGeneration)
        }
        selectedIndex = 0
        lastPointer = NSEvent.mouseLocation
        if cells.isEmpty { showPreview(for: nil) } else { select(0) }
        gridView.scroll(.zero)
    }

    private func loadPreview(_ gif: GiphyGif, into cell: GifCell, generation: Int) {
        guard let url = gif.previewURL else { return }
        if let cached = previewCache.object(forKey: url as NSURL) {
            cell.image = cached
            return
        }
        Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: result.0) else { return }
            guard let self, generation == self.searchGeneration else { return }
            self.previewCache.setObject(image, forKey: url as NSURL)
            cell.image = image
            // Thumbnail arrived after the cell was selected: use it as placeholder in the preview pane.
            if self.previewView.image == nil, self.cells.indices.contains(self.selectedIndex),
               self.cells[self.selectedIndex] === cell {
                self.previewView.image = image
            }
        }
    }

    private func select(_ index: Int, scroll: Bool = true) {
        guard !cells.isEmpty else { return }
        if selectedIndex < cells.count { cells[selectedIndex].isSelectedCell = false }
        selectedIndex = index
        let cell = cells[index]
        cell.isSelectedCell = true
        if scroll { cell.scrollToVisible(cell.bounds.insetBy(dx: 0, dy: -8)) }
        showPreview(for: index)
    }

    private func move(by delta: Int) {
        guard !cells.isEmpty else { return }
        lastPointer = NSEvent.mouseLocation
        select(min(max(selectedIndex + delta, 0), cells.count - 1))
    }

    /// Shows the grid thumbnail at once, then swaps in the larger rendition.
    /// Preview images come from GIPHY's media CDN, not the API, so they don't count against the API key's limit.
    private func showPreview(for index: Int?) {
        previewToken += 1
        let token = previewToken
        guard let index, index < gifs.count else {
            previewView.image = nil
            previewTitle.stringValue = ""
            return
        }
        let gif = gifs[index]
        previewTitle.stringValue = gif.title ?? ""
        previewTitle.toolTip = gif.title
        previewView.image = gif.previewURL.flatMap { previewCache.object(forKey: $0 as NSURL) }

        guard let url = gif.largePreviewURL else { return }
        if let cached = largePreviewCache.object(forKey: url as NSURL) {
            previewView.image = cached
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000) // skip GIFs you only pass over
            guard let self, token == self.previewToken else { return }
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: result.0) else { return }
            self.largePreviewCache.setObject(image, forKey: url as NSURL)
            guard token == self.previewToken else { return }
            self.previewView.image = image
        }
    }

    // MARK: Keyboard

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveLeft(_:)) where !cells.isEmpty: move(by: -1)
        case #selector(NSResponder.moveRight(_:)) where !cells.isEmpty: move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -Config.columns)
        case #selector(NSResponder.moveDown(_:)): move(by: Config.columns)
        case #selector(NSResponder.insertNewline(_:)):
            if searchField.stringValue != lastQuery {
                scheduleSearch(delay: 0) // results are stale: search first
            } else {
                let copyOnly = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                pasteSelected(copyOnly: copyOnly)
            }
        case #selector(NSResponder.cancelOperation(_:)): hidePanel(restoreFocus: true)
        default: return false
        }
        return true
    }

    // MARK: Paste

    private func pasteSelected(copyOnly: Bool) {
        guard !isPasting, selectedIndex < gifs.count, let url = gifs[selectedIndex].originalURL else { return }
        let name = gifs[selectedIndex].fileName(searchTerm: lastQuery, withExtension: includeGifExtension)
        isPasting = true
        setStatus("Downloading GIF…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await Giphy.download(url, name: name)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([file as NSURL])
                self.isPasting = false
                self.setStatus(self.helpText)
                self.hidePanel(restoreFocus: true)
                if !copyOnly && AXIsProcessTrusted() {
                    try? await Task.sleep(nanoseconds: 250_000_000) // let the target app regain focus
                    Self.sendCommandV()
                }
            } catch {
                self.isPasting = false
                self.setStatus("Download failed: \(error.localizedDescription)")
            }
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: API key

    @objc func promptForAPIKey() {
        let alert = NSAlert()
        alert.messageText = "GIPHY API key"
        alert.informativeText = "Create a free key at developers.giphy.com (Create an API Key → API)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = APIKeyStore.load() == nil ? "Paste key" : "Key saved. Paste a new one to replace it"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try APIKeyStore.save(key)
            gifs = []
            lastQuery = nil
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Entry point

@main
struct GifPasteMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}
