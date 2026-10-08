import AppKit
import Combine
import SwiftUI
import WhispererCore

// CLI mode: `Whisperer --transcribe file.wav [--model id] [--language en,pl] [--no-vad] [--json]` prints the
// transcript and exits.
let cli = CommandLine.arguments
if let i = cli.firstIndex(of: "--transcribe"), i + 1 < cli.count {
    let paths = Paths()
    let modelID = cli.firstIndex(of: "--model").flatMap { $0 + 1 < cli.count ? cli[$0 + 1] : nil } ?? "medium"
    let settings = LenientJSON.load(paths.settingsFile, defaults: AppSettings())
    do {
        let audio = try WAV.read(URL(fileURLWithPath: cli[i + 1]))
        var o = TranscribeOptions()
        o.prompt = TextProcessing.prompt(vocabulary: settings.vocabulary)
        o.language = cli.firstIndex(of: "--language").flatMap { $0 + 1 < cli.count ? cli[$0 + 1] : nil } ?? "en,pl"
        if !cli.contains("--no-vad") { o.vadModelPath = paths.vadModel?.path }
        let engine = Transcriber()
        let t = try engine.transcribe(AudioLevel.normalize(audio), modelPath: paths.modelFile(modelID).path, options: o)
        engine.unload()   // ggml-metal asserts at exit if a context is still alive
        let text = TextProcessing.finalize(t.text, replacements: settings.replacements, autocapitalize: true)
        if cli.contains("--json") {
            let o: [String: Any] = ["text": text, "raw": t.text, "noSpeech": t.noSpeech.map { Double($0) }, "ms": t.processingMs,
                                     "language": t.language, "vad": t.usedVAD]
            print(String(data: try JSONSerialization.data(withJSONObject: o), encoding: .utf8)!)
        } else { print(text) }
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
if let i = cli.firstIndex(of: "--render-pill"), i + 1 < cli.count {
    let wav = i + 2 < cli.count ? URL(fileURLWithPath: cli[i + 2]) : nil
    MainActor.assumeIsolated { PillRender.run(dir: URL(fileURLWithPath: cli[i + 1]), wav: wav) }
    exit(0)
}
if let i = cli.firstIndex(of: "--render-icon"), i + 1 < cli.count {
    IconRenderer.renderIconset(to: URL(fileURLWithPath: cli[i + 1]))
    exit(0)
}

// The app itself starts only with no arguments, `--background`, or what macOS itself adds (-psn_..., and
// -NS.../-Apple... defaults pairs). Anything else (a typo, a single-dash flag, a file path, a flag this build
// predates) is refused: three times on 2026-09-28 a mistyped test command started a second live copy on the
// real ~/Whisperer (reports in Akasa/ops/mistakes/).
func appLaunchArgumentsAreValid(_ args: [String]) -> String? {
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--background" || a.hasPrefix("-psn_") { i += 1; continue }
        if a.hasPrefix("-NS") || a.hasPrefix("-Apple") { i += 2; continue }   // "-NSKey value"
        return a
    }
    return nil
}
if let bad = appLaunchArgumentsAreValid(Array(cli.dropFirst())) {
    FileHandle.standardError.write("Whisperer: unknown argument \(bad). Known: --transcribe, --render-icon, --render-pill, --background\n".data(using: .utf8)!)
    exit(2)
}

// One copy only. Two would share ~/Whisperer, both hear the key, and one tap would record and paste twice.
// The lock is held for the life of the process (the kernel drops it on exit or crash).
let instanceLock: Int32 = {
    let dir = Paths().root
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent(".app.lock").path, O_CREAT | O_RDWR, 0o644)
    let otherCopy = NSRunningApplication.runningApplications(withBundleIdentifier: "uk.co.akasamedia.whisperer")
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0 || otherCopy {
        FileHandle.standardError.write("Whisperer is already running; not starting a second copy.\n".data(using: .utf8)!)
        exit(3)
    }
    return fd
}()
_ = instanceLock

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel.shared
    var dictation: DictationController!
    var statusItem: NSStatusItem!
    var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        dictation = DictationController(model: model)
        model.settingsChanged = { [weak self] old in
            guard let self else { return }
            self.dictation.applySettings()
            if old.showInDock != self.model.settings.showInDock { self.model.applyDockPolicy() }
            if old.showSuperwhisperHistory != self.model.settings.showSuperwhisperHistory { self.model.reloadHistory() }
            self.updateStatusIcon()
        }
        model.applyDockPolicy()
        setupStatusItem()
        model.reloadHistory()
        if !model.micAuthorized { model.requestMicrophone() }
        if !model.axTrusted { model.requestAccessibility() }
        dictation.ensureHotkey()
        dictation.warmUp()
        dictation.recoverInterrupted()
        // Weekly "is there a better voice model?" check; the timer only asks whether a week has passed.
        model.checkForBetterModels()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.checkForBetterModels() }
        }

        // Scriptable control (and the end-to-end test): toggle / cancel via distributed notifications.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("uk.co.akasamedia.whisperer.toggle"), object: nil, queue: .main) { _ in
            Task { @MainActor in self.dictation.toggle() }
        }
        dnc.addObserver(forName: .init("uk.co.akasamedia.whisperer.cancel"), object: nil, queue: .main) { _ in
            Task { @MainActor in self.dictation.cancel() }
        }
        // Open a screen: object = home | modes | vocabulary | configuration | sound | models | history.
        dnc.addObserver(forName: .init("uk.co.akasamedia.whisperer.show"), object: nil, queue: .main) { note in
            let name = note.object as? String
            Task { @MainActor in
                if let r = name.flatMap(Route.init(rawValue:)) { self.model.route = r }
                self.showWindow()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                self.model.refreshPermissions()
                self.model.refreshInstalledModels()
                self.model.reloadHistoryIfStale()
            }
        }
        // Started by the login item (the Mac booted minutes ago): stay in the menu bar.
        let atLogin = ProcessInfo.processInfo.systemUptime < 180
        if !cli.contains("--background") && !atLogin { showWindow() }
    }

    func applicationWillTerminate(_ note: Notification) {
        model.persistNow()
        // ggml-metal asserts at exit if a model is still loaded. Never block Quit on a running transcription:
        // if the engine is busy, leave without running the library's exit handlers.
        if !model.engine.tryUnload() { _exit(0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: window

    func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 880),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Whisperer"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 680, height: 520)
            w.contentView = NSHostingView(rootView: RootView().environmentObject(model)
                .environment(\.toggleRecording, { [weak self] in self?.dictation.toggle() }))
            w.center()
            w.setFrameAutosaveName("WhispererMain")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
        model.$phase.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusIcon() }.store(in: &bag)
    }
    private var bag = Set<AnyCancellable>()

    func updateStatusIcon() {
        let symbol: String
        switch model.phase {
        case .listening: symbol = "record.circle.fill"
        case .transcribing: symbol = "ellipsis.circle"
        default: symbol = "waveform"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whisperer")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let listening: Bool = { if case .listening = model.phase { return true }; return false }()
        let key = model.settings.triggerKey.label
        let rec = NSMenuItem(title: listening ? "Stop Recording" : "Start Recording (tap \(key))", action: #selector(toggleRec), keyEquivalent: "")
        rec.target = self
        menu.addItem(rec)
        if listening {
            let c = NSMenuItem(title: "Cancel Recording", action: #selector(cancelRec), keyEquivalent: "")
            c.target = self
            menu.addItem(c)
        }
        if model.lastTranscript != nil {
            let copy = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLast), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        menu.addItem(.separator())
        let modes = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in model.settings.modes {
            let it = NSMenuItem(title: m.name, action: #selector(pickMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.key
            it.state = m.key == model.settings.activeModeKey ? .on : .off
            sub.addItem(it)
        }
        modes.submenu = sub
        menu.addItem(modes)
        if !model.settings.pillPosition.isEmpty {
            let r = NSMenuItem(title: "Reset Pill Position", action: #selector(resetPill), keyEquivalent: "")
            r.target = self
            menu.addItem(r)
        }
        if !model.axTrusted || !model.micAuthorized {
            let p = NSMenuItem(title: "Permissions needed…", action: #selector(openWin), keyEquivalent: "")
            p.target = self
            menu.addItem(p)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Whisperer", action: #selector(openWin), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit Whisperer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleRec() { dictation.toggle() }
    @objc func cancelRec() { dictation.cancel() }
    @objc func copyLast() {
        guard let t = model.lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }
    @objc func openWin() { showWindow() }
    @objc func resetPill() { dictation.pill.resetPosition() }
    @objc func pickMode(_ item: NSMenuItem) { if let k = item.representedObject as? String { model.setActiveMode(k) } }
}

struct ToggleRecordingKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var toggleRecording: () -> Void {
        get { self[ToggleRecordingKey.self] }
        set { self[ToggleRecordingKey.self] = newValue }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
