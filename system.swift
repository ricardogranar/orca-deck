// System helpers that keep the deck working without babysitting:
//  • DockGuard    – keeps the macOS Dock off the phone screen (and moves it back if it got there).
//  • PhoneLink    – makes sure OpenDisplay is running and restarts it when the phone is plugged in but no screen appears.
//  • OrcaCompat   – checks the installed Orca CLI still has every command the deck uses.
import AppKit
import ApplicationServices
import IOKit

// MARK: - geometry

/// Quartz (top-left origin) rect of a screen. Event taps and CGWarp use Quartz; NSScreen uses Cocoa (bottom-left).
func quartzRect(_ s: NSScreen) -> CGRect {
    let h = NSScreen.screens.first?.frame.maxY ?? 0
    let f = s.frame
    return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
}

enum DockEdge: String { case bottom, left, right }

func dockEdge() -> DockEdge {
    CFPreferencesAppSynchronize("com.apple.dock" as CFString)
    let v = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
    return DockEdge(rawValue: v ?? "bottom") ?? .bottom
}

/// Parts of `s`'s Dock-side edge that are not shared with another screen (the pointer can't cross those parts,
/// so it can push against them). Returned as ranges along the edge, in Quartz coordinates.
func exposedSpans(of s: NSScreen, edge: DockEdge) -> [ClosedRange<CGFloat>] {
    let r = quartzRect(s)
    let along: ClosedRange<CGFloat> = edge == .bottom ? r.minX...r.maxX : r.minY...r.maxY
    var blocked: [ClosedRange<CGFloat>] = []
    for o in NSScreen.screens where o != s {
        let q = quartzRect(o)
        switch edge {
        case .bottom: if abs(q.minY - r.maxY) < 2 { blocked.append(q.minX...q.maxX) }
        case .left:   if abs(q.maxX - r.minX) < 2 { blocked.append(q.minY...q.maxY) }
        case .right:  if abs(q.minX - r.maxX) < 2 { blocked.append(q.minY...q.maxY) }
        }
    }
    var spans = [along]
    for b in blocked {
        spans = spans.flatMap { sp -> [ClosedRange<CGFloat>] in
            guard b.overlaps(sp) else { return [sp] }
            var out: [ClosedRange<CGFloat>] = []
            if b.lowerBound > sp.lowerBound { out.append(sp.lowerBound...b.lowerBound) }
            if b.upperBound < sp.upperBound { out.append(b.upperBound...sp.upperBound) }
            return out
        }
    }
    return spans.filter { $0.upperBound - $0.lowerBound > 8 }
}

/// How much of the screen the Dock covers on its edge (0 when the Dock is elsewhere).
func dockInset(on s: NSScreen, edge: DockEdge) -> CGFloat {
    let f = s.frame, v = s.visibleFrame
    switch edge {
    case .bottom: return v.minY - f.minY
    case .left:   return v.minX - f.minX
    case .right:  return f.maxX - v.maxX
    }
}

// MARK: - Dock guard

/// macOS moves the Dock to whichever display the pointer pushes against the Dock edge of. On the phone that
/// happens easily: OpenDisplay turns a touch or swipe near the edge into real mouse events. With Accessibility
/// permission an event tap nudges pointer events in a thin strip along the phone's Dock edge a few points inward,
/// so the pointer never reaches it (same idea as DockPin). If the Dock still lands on the phone, it is pushed
/// back to the main display.
final class DockGuard {
    var enabled = true { didSet { update() } }
    var phone: () -> NSScreen? = { nil }
    private(set) var tap: CFMachPort?
    private var zones: [(rect: CGRect, edge: DockEdge, line: CGFloat)] = []
    private var rescuing = false
    private var lastRescue: TimeInterval = 0
    private var asked = false
    private var rescueFails = 0
    private var lastArrange: TimeInterval = 0

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Show the system "allow Accessibility" prompt (once per launch).
    func requestPermission() {
        asked = true
        let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Call on launch, on screen changes and every couple of seconds.
    func update() {
        guard enabled else { removeTap(); zones = []; return }
        if !DockGuard.trusted {
            if !asked { requestPermission() }
            removeTap()
        } else if tap == nil { installTap() }
        keepPhoneOffDockSide()
        rebuildZones()
        rescueIfNeeded()
    }

    /// Screens were added, removed or rearranged: give the rescue another chance.
    func screensChanged() { rescueFails = 0; update() }

    /// The Dock only lives on a display whose Dock-side edge is completely free. OpenDisplay adds the phone right
    /// next to the main display (e.g. touching its left edge), and with a left Dock that edge is then partly
    /// covered, so macOS moves the Dock to the phone and no pointer push can bring it back. A side Dock also
    /// goes to the display furthest out on its side. So when the phone touches the main display's Dock edge,
    /// is the outermost display on a side Dock's side, or still has the Dock after a failed rescue, move the
    /// phone screen in the display arrangement: centred above the main display, else below it, else on its
    /// other side, never touching the main display's Dock edge. Needs no permission.
    private func keepPhoneOffDockSide() {
        let edge = dockEdge()
        guard let s = phone(), let main = NSScreen.screens.first, s != main else { return }
        let others = NSScreen.screens.filter { $0 != s }.map(quartzRect)
        let m = quartzRect(main), p = quartzRect(s)
        func touchesDockEdge(_ r: CGRect) -> Bool {
            switch edge {
            case .left:   return abs(r.maxX - m.minX) < 2 && r.maxY > m.minY + 1 && r.minY < m.maxY - 1
            case .right:  return abs(r.minX - m.maxX) < 2 && r.maxY > m.minY + 1 && r.minY < m.maxY - 1
            case .bottom: return abs(r.minY - m.maxY) < 2 && r.maxX > m.minX + 1 && r.minX < m.maxX - 1
            }
        }
        func outermost(_ r: CGRect) -> Bool {
            switch edge {
            case .left:   return r.minX <= (others.map(\.minX).min() ?? 0) + 0.5
            case .right:  return r.maxX >= (others.map(\.maxX).max() ?? 0) - 0.5
            case .bottom: return false
            }
        }
        let stuck = rescueFails >= 2 && dockInset(on: s, edge: edge) > 0.5
        guard touchesDockEdge(p) || outermost(p) || stuck else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastArrange > 5 else { return }
        lastArrange = now
        let cx = (m.midX - p.width / 2).rounded(), cy = (m.midY - p.height / 2).rounded()
        var candidates = [CGPoint(x: cx, y: m.minY - p.height)]                       // above
        if edge != .bottom { candidates.append(CGPoint(x: cx, y: m.maxY)) }            // below
        if edge != .right { candidates.append(CGPoint(x: m.maxX, y: cy)) }             // right
        if edge != .left { candidates.append(CGPoint(x: m.minX - p.width, y: cy)) }    // left
        guard let o = candidates.first(where: { c in
            let r = CGRect(origin: c, size: p.size)
            return !others.contains { $0.insetBy(dx: 1, dy: 1).intersects(r) } && !touchesDockEdge(r) && !outermost(r)
        }) else { deckLog("dock guard: no free place to move the phone away from the \(edge.rawValue) Dock"); return }
        guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y))
        let err = CGCompleteDisplayConfiguration(cfg, .permanently)
        let why = touchesDockEdge(p) ? "touched the main display's Dock edge" : outermost(p) ? "was outermost on the Dock side" : "kept the Dock"
        deckLog("dock guard: phone \(why) (\(edge.rawValue) Dock); moved it to \(Int(o.x)),\(Int(o.y)) (err \(err.rawValue))")
    }

    var status: String { !enabled ? "off" : !DockGuard.trusted ? "needsPermission" : tap == nil ? "error" : "on" }

    private func rebuildZones() {
        guard let s = phone(), s != NSScreen.screens.first else { zones = []; return }
        let edge = dockEdge(), r = quartzRect(s)
        zones = exposedSpans(of: s, edge: edge).map { sp in
            switch edge {
            case .bottom: return (CGRect(x: sp.lowerBound, y: r.maxY - 6, width: sp.upperBound - sp.lowerBound, height: 9), edge, r.maxY - 1)
            case .left:   return (CGRect(x: r.minX - 3, y: sp.lowerBound, width: 9, height: sp.upperBound - sp.lowerBound), edge, r.minX)
            case .right:  return (CGRect(x: r.maxX - 6, y: sp.lowerBound, width: 9, height: sp.upperBound - sp.lowerBound), edge, r.maxX - 1)
            }
        }
    }

    private func installTap() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            if let refcon {
                let g = Unmanaged<DockGuard>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = g.tap { CGEvent.tapEnable(tap: t, enable: true) }
                } else { g.filter(event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { deckLog("dock guard: could not create event tap"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        deckLog("dock guard: on")
    }

    private func removeTap() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        CFMachPortInvalidate(t)
        tap = nil
    }

    private func filter(_ e: CGEvent) {
        guard !rescuing else { return }
        let p = e.location
        for z in zones where z.rect.contains(p) {
            var q = p
            switch z.edge {
            case .bottom: q.y = z.line - 7
            case .left:   q.x = z.line + 7
            case .right:  q.x = z.line - 7
            }
            e.location = q
            return
        }
    }

    // MARK: rescue

    /// If the Dock is on the phone, push the pointer against the main display's Dock edge, which makes macOS
    /// move it back there, then return the pointer to where it was.
    private func rescueIfNeeded() {
        guard DockGuard.trusted, !rescuing, let s = phone(), let main = NSScreen.screens.first, s != main else { return }
        let edge = dockEdge()
        guard dockInset(on: s, edge: edge) > 0.5 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Two failed pushes in a row: stop moving the pointer around until the screens change.
        guard rescueFails < 2, now - lastRescue > 4, NSEvent.pressedMouseButtons == 0 else { return }
        guard let span = exposedSpans(of: main, edge: edge).max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) })
        else { return }
        lastRescue = now
        rescuing = true
        deckLog("dock guard: Dock is on the phone (\(edge.rawValue)); moving it back")
        let r = quartzRect(main), mid = (span.lowerBound + span.upperBound) / 2
        let (edgePoint, dx, dy): (CGPoint, Int64, Int64) = {
            switch edge {
            case .bottom: return (CGPoint(x: mid, y: r.maxY - 1), 0, 6)
            case .left:   return (CGPoint(x: r.minX, y: mid), -6, 0)
            case .right:  return (CGPoint(x: r.maxX - 1, y: mid), 6, 0)
            }
        }()
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        let back = NSEvent.mouseLocation
        let restore = CGPoint(x: back.x, y: h - back.y)
        CGWarpMouseCursorPosition(edgePoint)
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            n += 1
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: edgePoint, mouseButton: .left) {
                e.setIntegerValueField(.mouseEventDeltaX, value: dx)
                e.setIntegerValueField(.mouseEventDeltaY, value: dy)
                e.post(tap: .cghidEventTap)
            }
            let moved = dockInset(on: self.phone() ?? s, edge: edge) < 0.5   // fresh NSScreen: visibleFrame is a snapshot
            if moved || n > 75 {
                t.invalidate()
                CGWarpMouseCursorPosition(restore)
                CGAssociateMouseAndMouseCursorPosition(1)
                self.rescuing = false
                self.rescueFails = moved ? 0 : self.rescueFails + 1
                deckLog("dock guard: rescue \(moved ? "done" : "did not move the Dock")")
            }
        }
    }
}

// MARK: - OpenDisplay link

/// OpenDisplay's Mac app is what turns the phone into a screen. After a reboot it does not always start, and it
/// can get stuck (running, phone plugged in, no screen). This starts it when it isn't running and restarts it
/// when the phone is on USB but no phone screen shows up for a while.
final class PhoneLink {
    static let bundleIDs = ["com.peetzweg.opensidecar.mac", "com.peetzweg.opendisplay.mac"]
    var hasScreen: () -> Bool = { false }
    var onChange: (() -> Void)?
    var autoRestart = true

    private(set) var state = "unknown"          // connected | starting | waiting | restarting | notInstalled
    private var missingSince: TimeInterval?
    private var lastRestart: TimeInterval = 0
    private var restartsThisPlug = 0
    private var lastLaunch: TimeInterval = 0

    var appURL: URL? {
        for id in PhoneLink.bundleIDs { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u } }
        let fallback = URL(fileURLWithPath: "/Applications/OpenDisplay.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    var running: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            PhoneLink.bundleIDs.contains($0.bundleIdentifier ?? "") || $0.bundleURL?.lastPathComponent == "OpenDisplay.app"
        }
    }

    /// An iPhone/iPad attached over USB (OpenDisplay also works over Wi-Fi; then this is false and we never restart).
    static func phoneOnUSB() -> Bool {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(it) }
        var found = false
        while case let d = IOIteratorNext(it), d != 0 {
            let name = IORegistryEntryCreateCFProperty(d, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? ""
            if name == "iPhone" || name == "iPad" { found = true }
            IOObjectRelease(d)
        }
        return found
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let old = state
        defer { if state != old { deckLog("phone link: \(old) → \(state)"); onChange?() } }
        if hasScreen() { state = "connected"; missingSince = nil; restartsThisPlug = 0; return }
        guard let url = appURL else { state = "notInstalled"; return }
        let usb = PhoneLink.phoneOnUSB()
        if !usb { restartsThisPlug = 0 }
        guard let app = running else {
            if now - lastLaunch > 20 { launch(url); lastLaunch = now }
            state = "starting"; missingSince = now; return
        }
        if missingSince == nil { missingSince = now }
        state = "waiting"
        // Phone plugged in, OpenDisplay running, still no screen after 45 s: OpenDisplay is stuck. Restart it,
        // at most 3 times per plug-in and not more than once every 2 minutes.
        guard autoRestart, usb, now - (missingSince ?? now) > 45, now - lastRestart > 120, restartsThisPlug < 3,
              now - lastLaunch > 45 else { return }
        lastRestart = now; restartsThisPlug += 1; missingSince = now
        state = "restarting"
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let still = self.running, !still.isTerminated { still.forceTerminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.launch(url); self.lastLaunch = ProcessInfo.processInfo.systemUptime }
        }
    }

    private func launch(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            if let err { deckLog("phone link: could not open OpenDisplay: \(err.localizedDescription)") }
        }
    }

    func restartNow() {
        guard let url = appURL else { return }
        lastRestart = ProcessInfo.processInfo.systemUptime
        if let app = running { app.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let still = self.running, !still.isTerminated { still.forceTerminate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.launch(url) }
        }
    }
}

// MARK: - Orca CLI compatibility

/// Commands the deck relies on. `orca agent-context --json` lists every command of the installed CLI and works
/// even when Orca isn't running, so a missing one means Orca changed and the deck needs an update.
enum OrcaCompat {
    static let needed = ["worktree ps", "worktree activate", "worktree set", "terminal list", "terminal switch",
                         "terminal send", "terminal read", "agent read"]

    static func check() -> [String: Any] {
        var info: [String: Any] = ["cli": orcaBin, "found": FileManager.default.isExecutableFile(atPath: orcaBin)]
        if let v = orcaAppURL.flatMap({ Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }) { info["version"] = v }
        guard info["found"] as? Bool == true else { info["missing"] = needed; return info }
        let out = runOrcaRaw(["agent-context", "--json"], timeout: 15)
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return info }
        let root = (obj["result"] as? [String: Any]) ?? obj
        let cmds = (root["commands"] as? [[String: Any]] ?? []).compactMap { ($0["path"] as? [String])?.joined(separator: " ") }
        guard !cmds.isEmpty else { return info }
        info["missing"] = needed.filter { !cmds.contains($0) }
        return info
    }
}
