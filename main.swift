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
            if window.screen == s { return }
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
