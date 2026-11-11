// Orca Deck — a glanceable side display for Orca agents.
// Opens full screen (its own Space) on the iPhone/OpenDisplay screen, polls the `orca` CLI,
// and lets the HTML UI run a whitelisted set of orca commands.
import AppKit
import WebKit

let orcaBin: String = {
    if let p = ProcessInfo.processInfo.environment["ORCA_CLI_COMMAND"], FileManager.default.isExecutableFile(atPath: p) { return p }
    return "/Applications/Orca.app/Contents/Resources/bin/orca"
}()

/// Commands the UI may run. First two args must match one of these.
let allowed: Set<String> = [
    "worktree ps", "worktree activate", "worktree set",
    "terminal list", "terminal switch", "terminal send", "terminal read",
]

func runOrca(_ args: [String], timeout: TimeInterval = 20) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: orcaBin)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
    p.environment = env
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return #"{"ok":false,"error":{"message":"cannot run orca"}}"# }
    let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let edata = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    timer.cancel()
    let s = String(data: data, encoding: .utf8) ?? ""
    if s.trimmingCharacters(in: .whitespacesAndNewlines).first == "{" { return s }
    let msg = (String(data: edata, encoding: .utf8) ?? s).trimmingCharacters(in: .whitespacesAndNewlines)
    let obj: [String: Any] = ["ok": false, "error": ["message": msg.isEmpty ? "orca exited without output" : msg]]
    return (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
}

/// Small debug log at ~/Library/Logs/OrcaDeck.log (touch detection, to tune the pointer hand-back).
func deckLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OrcaDeck.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        if (try? h.seekToEnd()) ?? 0 > 512_000 { try? h.truncate(atOffset: 0) }
        h.write(line.data(using: .utf8)!); try? h.close()
    } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

final class FirstMouseWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Deck: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var web: FirstMouseWebView!
    var pollTimer: Timer?
    var polling = false
    /// The app the user was in before touching the deck; we hand focus back to it after a tap.
    var lastOtherApp: NSRunningApplication?
    let q = DispatchQueue(label: "deck.orca", attributes: .concurrent)

    // Touch → pointer hand-back. OpenDisplay turns each touch into real mouse events, which drags the Mac
    // pointer onto the phone. We hide it while the finger is down and put it back where it was afterwards.
    var restoreCursor = true
    var lastOffDeck: NSPoint?          // last pointer position seen outside the deck screen
    var lastOffDeckAt: TimeInterval = 0
    var touchFrom: NSPoint?            // where to send the pointer back when the current touch ends
    var touchStartedAt: TimeInterval = 0
    var cursorHidden = false

    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let name = ProcessInfo.processInfo.environment["DECK_SCREEN"],
           let s = screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) { return s }
        return screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("iPhone")
            || $0.localizedName.localizedCaseInsensitiveContains("OpenDisplay") })
    }

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    /// Move to the iPhone screen and go native full screen there (own Space, no menu bar).
    func placeAndFullScreen() {
        guard let s = targetScreen() else { return }
        if isFullScreen {
            // Rotating the phone resizes the OpenDisplay screen (936×526 ↔ 526×936). macOS normally resizes
            // full-screen windows along with it; if it didn't, leave and re-enter full screen to fit again.
            let fits = abs(window.frame.width - s.frame.width) < 2 && abs(window.frame.height - s.frame.height) < 2
            if window.screen == s && fits { return }
            window.toggleFullScreen(nil)          // leave, then re-enter on the right screen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.placeAndFullScreen() }
            return
        }
        window.setFrame(s.visibleFrame, display: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !self.isFullScreen && self.window.screen == s { self.window.toggleFullScreen(nil) }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "orca")
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 936, height: 526),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Orca Deck"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("")
        web = FirstMouseWebView(frame: window.contentView!.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        window.contentView!.addSubview(web)

        let res = Bundle.main.resourceURL!.appendingPathComponent("web")
        let dev = ProcessInfo.processInfo.environment["DECK_WEB_DIR"].map { URL(fileURLWithPath: $0) }
        let dir = dev ?? res
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)

        // Remember where focus was so a tap on the phone doesn't steal the keyboard from Orca.
        lastOtherApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.lastOtherApp = app }
        }
        // Focus hand-back after a tap is driven from the UI ("yield" op), so "Abrir en Orca" can skip it.

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        placeAndFullScreen()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.placeAndFullScreen() }
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        startPointerHandBack()
    }

    // MARK: pointer hand-back

    func deckFrame() -> NSRect? { (window.screen ?? targetScreen())?.frame }

    func startPointerHandBack() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.trackPointer() }
        RunLoop.main.add(t, forMode: .common)
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            if e.type == .leftMouseDown { self?.touchBegan(e) } else { self?.touchEnded() }
            return e
        }
    }

    func trackPointer() {
        let p = NSEvent.mouseLocation
        if let f = deckFrame(), !f.contains(p) { lastOffDeck = p; lastOffDeckAt = ProcessInfo.processInfo.systemUptime }
        // Safety net: never leave the pointer hidden (e.g. a lost mouse-up).
        if cursorHidden && touchFrom == nil { showPointer() }
        if touchFrom != nil && ProcessInfo.processInfo.systemUptime - touchStartedAt > 15 { touchEnded() }
    }

    /// A touch is a mouse-down posted by OpenDisplay, or a pointer that teleported onto the deck from another
    /// screen a moment ago (a real mouse has to travel there first and sits on the deck before clicking).
    func touchBegan(_ e: NSEvent) {
        guard restoreCursor, e.window === window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pid = pid_t(e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0)
        let poster = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let fromOpenDisplay = poster.hasPrefix("com.peetzweg.opensidecar")
        let teleported = now - lastOffDeckAt < 0.35
        deckLog("down pid=\(pid) poster=\(poster) teleported=\(teleported) from=\(lastOffDeck.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-")")
        guard fromOpenDisplay || teleported, let from = lastOffDeck else { return }
        touchFrom = from
        touchStartedAt = now
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }

    func touchEnded() {
        guard let from = touchFrom else { return }
        touchFrom = nil
        // Let the click land (and OpenDisplay finish its own events) before moving the pointer away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let upAt = NSEvent.mouseLocation
            self.warp(to: from)
            self.showPointer()
            // If OpenDisplay re-posted the pointer onto the phone right after, send it back once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let p = NSEvent.mouseLocation
                if self.touchFrom == nil, abs(p.x - upAt.x) < 2, abs(p.y - upAt.y) < 2 { self.warp(to: from) }
            }
        }
    }

    func warp(to p: NSPoint) {
        // Cocoa uses bottom-left origin on the primary screen; Quartz uses top-left.
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: h - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func showPointer() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }

    func yieldFocus() {
        guard NSApp.isActive else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let target = [lastOtherApp].compactMap { $0 }.first { !$0.isTerminated && $0.processIdentifier != me }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.stablyai.orca").first
        target?.activate(options: [])
    }

    /// Bring Orca in front of whatever is on the Mac screens. macOS only lets the *active* app hand
    /// activation to another, so make sure we are active first, then explicitly yield to Orca.
    func bringOrcaToFront() {
        guard let orcaApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.stablyai.orca").first else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Orca.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: orcaApp) }
        orcaApp.activate(options: [.activateAllWindows])
        lastOtherApp = orcaApp
        // Fallback through LaunchServices in case activation was refused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.stablyai.orca" {
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
                NSWorkspace.shared.openApplication(at: orcaApp.bundleURL ?? URL(fileURLWithPath: "/Applications/Orca.app"),
                                                   configuration: cfg)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Clicking the Dock icon while running: bring the deck back and re-pin it to the iPhone screen.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        placeAndFullScreen()
        poll()
        return false
    }

    func windowDidEnterFullScreen(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.yieldFocus() }
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        poll()
        // Debug: DECK_SNAPSHOT=/path.png writes a picture of the deck (no Screen Recording permission needed).
        if let path = ProcessInfo.processInfo.environment["DECK_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.snapshot(to: path) }
        }
    }

    func snapshot(to path: String) {
        let js = ProcessInfo.processInfo.environment["DECK_SNAPSHOT_JS"] ?? ""
        web.evaluateJavaScript(js.isEmpty ? "0" : js) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.web.takeSnapshot(with: nil) { img, _ in
                    guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    func poll() {
        if polling { return }
        polling = true
        q.async {
            let g = DispatchGroup()
            var ps = "", terms = ""
            g.enter(); self.q.async { ps = runOrca(["worktree", "ps", "--json"]); g.leave() }
            g.enter(); self.q.async { terms = runOrca(["terminal", "list", "--json"]); g.leave() }
            g.wait()
            DispatchQueue.main.async {
                self.polling = false
                self.web.evaluateJavaScript("window.deck && deck.update(\(ps), \(terms))")
            }
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let id = body["id"] as? Int else { return }
        let reply: (String) -> Void = { json in
            DispatchQueue.main.async { self.web.evaluateJavaScript("deck.reply(\(id), \(json))") }
        }
        switch body["op"] as? String {
        case "orca":
            let args = (body["args"] as? [String]) ?? []
            guard args.count >= 2, allowed.contains("\(args[0]) \(args[1])") else {
                reply(#"{"ok":false,"error":{"message":"not allowed"}}"#); return
            }
            q.async { reply(runOrca(args + ["--json"])) }
        case "focusOrca":
            bringOrcaToFront()
            reply("{\"ok\":true}")
        case "yield":
            yieldFocus()
            reply("{\"ok\":true}")
        case "theme":
            // Match the window behind the canvas to the deck's theme (Orca's --background).
            let dark = (body["dark"] as? Bool) ?? true
            window.backgroundColor = dark ? NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1) : .white
            reply("{\"ok\":true}")
        case "prefs":
            if let r = body["restoreCursor"] as? Bool { restoreCursor = r; if !r { touchFrom = nil; showPointer() } }
            reply("{\"ok\":true}")
        case "sound":
            NSSound(named: NSSound.Name((body["name"] as? String) ?? "Glass"))?.play()
            reply("{\"ok\":true}")
        default:
            reply(#"{"ok":false}"#)
        }
    }
}

let app = NSApplication.shared
let deck = Deck()
app.delegate = deck
app.setActivationPolicy(.regular)
app.run()
