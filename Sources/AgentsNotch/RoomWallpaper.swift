import AppKit
import Combine
import IOKit.ps
import NotchCore
import SwiftUI
import WebKit

/// The agents' house as the desktop wallpaper: room/index.html in a window just above the desktop picture.
/// The window never takes the mouse, so the desktop icons keep working; hover and clicks on bare desktop
/// are forwarded to the page, and a click on a Clawd opens that agent's chat.
@MainActor
final class RoomWallpaper: NSObject {
    private let store: Store
    private var window: NSWindow?
    private(set) var web: WKWebView?
    private var subs: Set<AnyCancellable> = []
    private var monitor: Any?
    private var pinchTap: CFMachPort?
    private var lastJSON = ""
    private var lastMove = 0.0
    private var hovering = false
    private let tip = RoomTip()
    private var powerTimer: Timer?
    private var sentActive: Bool?
    private var sentFps = 0
    /// The other screens' windows (see RoomScreens.swift) and where a click started.
    var extras: [CGDirectDisplayID: RoomExtraScreen] = [:]
    var settingsSubs: Set<AnyCancellable> = []
    private var pressed: (NSPoint, Double)?
    private let info = RoomInfoFeed()
    /// Whether the house page is drawing (an agent works or someone walks); the other screens follow it.
    private(set) var houseAwake = true

    init(store: Store) { self.store = store }

    var isRunning: Bool { window != nil }

    func start() {
        guard window == nil else { return }
        guard let page = Self.page else { NSLog("agents-notch: room/index.html not found"); return }
        guard let screen = NSScreen.screens.first else { return }

        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.canHide = false
        w.isRestorable = false
        w.displaysWhenScreenProfileChanges = true
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.userContentController.add(MessageProxy(self), name: "room")
        let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
        web.navigationDelegate = self
        if #available(macOS 13.3, *) { web.isInspectable = true }
        var url = URLComponents(url: page, resolvingAgainstBaseURL: false)
        // gl=1: the page draws through WebGL, about half the CPU of the 2D canvas (docs/research/native-wallpaper.md)
        url?.queryItems = [URLQueryItem(name: "nodemo", value: "1"), URLQueryItem(name: "gl", value: "1")]
        web.loadFileURL(url?.url ?? page, allowingReadAccessTo: page.deletingLastPathComponent())
        w.contentView = web
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w
        self.web = web
        observeRoomSettings()

        store.$agents.combineLatest(store.$hooks)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.push() }
            .store(in: &subs)
        info.start(store: store, changed: { [weak self] in self?.push() }, send: { [weak self] js in self?.web?.evaluateJavaScript(js) })
        // A desktop-level window doesn't always follow to a new Space; bring it along when it got left behind.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                guard let w = self?.window, !w.isOnActiveSpace else { return }
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
                w.orderFrontRegardless()
            }
            .store(in: &subs)
        // Battery: nothing is drawn while the desktop is covered, and fewer frames are drawn on battery.
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: w)
            .sink { [weak self] _ in self?.syncPower() }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncPower() }
            .store(in: &subs)
        powerTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPower() }
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.fitScreen() }
            .store(in: &subs)
        startPinchTap()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .smartMagnify, .scrollWheel, .keyDown]) { [weak self] e in
            let type = e.type
            // Esc on the desktop goes back to the overview; macOS only delivers keys here with Accessibility access
            if type == .keyDown {
                guard e.keyCode == 53, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
                MainActor.assumeIsolated { self?.web?.evaluateJavaScript("room.resetView()") }
                return
            }
            let scroll = type == .scrollWheel && e.hasPreciseScrollingDeltas ? (e.scrollingDeltaX, e.scrollingDeltaY) : (0, 0)
            MainActor.assumeIsolated { self?.mouse(type, scroll: scroll) }
        }
    }

    /// A global monitor is never sent trackpad pinches (they go to the app under the cursor, Finder on the desktop),
    /// so they are read from a listen-only event tap on the session. macOS only feeds that tap with Input Monitoring
    /// allowed: without it the app asks once, and the tap is made again as soon as the permission is given.
    private var pinchTapAllowed = false
    private var pinchWatch: Timer?
    private func startPinchTap() {
        pinchTapAllowed = CGPreflightListenEventAccess()
        if !pinchTapAllowed {
            _ = CGRequestListenEventAccess()
            pinchWatch?.invalidate()
            pinchWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, CGPreflightListenEventAccess() else { return }
                    t.invalidate(); self.pinchWatch = nil
                    if let old = self.pinchTap { CGEvent.tapEnable(tap: old, enable: false); CFMachPortInvalidate(old); self.pinchTap = nil }
                    self.startPinchTap()
                }
            }
        }
        let callback: CGEventTapCallBack = { _, type, event, ref in
            guard let ref else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<RoomWallpaper>.fromOpaque(ref).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let tap = me.pinchTap { CGEvent.tapEnable(tap: tap, enable: true) } }
            } else if let e = NSEvent(cgEvent: event), e.type == .magnify {
                let m = e.magnification
                MainActor.assumeIsolated { me.mouse(.magnify, magnify: m) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(1) << 29 | CGEventMask(1) << CGEventMask(NSEvent.EventType.magnify.rawValue), // pinches come as gesture events (29)
                                          callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { NSLog("agents-notch: no event tap for trackpad pinches"); return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pinchTap = tap
    }

    func stop() {
        powerTimer?.invalidate()
        powerTimer = nil
        sentActive = nil
        sentFps = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let pinchTap { CGEvent.tapEnable(tap: pinchTap, enable: false); CFMachPortInvalidate(pinchTap) }
        pinchTap = nil
        pinchWatch?.invalidate(); pinchWatch = nil
        subs.removeAll()
        removeExtras()
        info.stop()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "room")
        window?.orderOut(nil)
        window = nil
        tip.hide()
        web = nil
        lastJSON = ""
    }

    func syncPower() {
        guard let w = window, let web else { return }
        let visible = w.occlusionState.contains(.visible)
        if visible != sentActive { sentActive = visible; web.evaluateJavaScript("room.setActive(\(visible))") }
        let fps = Self.fps
        if fps != sentFps { sentFps = fps; web.evaluateJavaScript("room.setFps(\(fps))") }
        extras.values.forEach { $0.sync(fps: fps) }
        syncInsets()
    }

    /// The menu bar and the Dock cover part of the wallpaper; the page keeps the house and the city's street clear of them,
    /// and the islands clear of the column of desktop icons on the right (unless Finder hides the desktop).
    private var sentInsets: (CGFloat, CGFloat, CGFloat)?
    private func syncInsets() {
        guard let screen = NSScreen.screens.first, let web else { return }
        let top = screen.frame.maxY - screen.visibleFrame.maxY, bottom = screen.visibleFrame.minY - screen.frame.minY
        let icons = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool ?? true
        let right: CGFloat = icons ? 120 : 0
        if let s = sentInsets, s == (top, bottom, right) { return }
        sentInsets = (top, bottom, right)
        web.evaluateJavaScript("room.setInsets({top: \(top), bottom: \(bottom), right: \(right)})")
    }

    static var fps: Int { AppSettings.shared.room.fps(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, onBattery: onBattery) }

    private static var onBattery: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }

    private func fitScreen() {
        guard let w = window, let screen = NSScreen.screens.first else { return }
        w.setFrame(screen.frame, display: true)
        syncScreens()
        syncInsets()
    }

    // MARK: agents

    /// The agents as the page wants them; only changes are sent.
    private func push() {
        info.track(store.shown)
        let json = Self.rows(store.shown, contexts: info.contexts)
        guard json != lastJSON else { return }
        lastJSON = json
        web?.evaluateJavaScript("window.room && room.setAgents(\(json)); true") { _, error in
            if let error { NSLog("agents-notch: room update failed: \(error)") }
        }
    }

    /// The agents as `room.setAgents(...)` takes them, as JSON; the screen saver gets the same rows (RoomSaverFeed.swift).
    static func rows(_ agents: [Agent], contexts: [String: Double]) -> String {
        let rows: [[String: Any]] = agents.map { a in
            var r: [String: Any] = ["id": a.id, "title": a.title, "project": a.project, "vendor": a.vendor.rawValue, "state": Self.state(a.state)]
            if let v = a.activity { r["activity"] = v }
            if let v = a.parentId { r["parentId"] = v }
            if let v = a.shortModel { r["model"] = v }
            if let v = a.ask { r["ask"] = v }
            if let v = contexts[a.id] { r["context"] = v }
            return r
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func state(_ s: AgentState) -> String {
        switch s {
        case .working: "working"
        case .waiting: "waiting"
        case .error: "error"
        case .done: "done"
        }
    }

    fileprivate func received(_ body: Any) {
        guard let msg = body as? [String: Any] else { return }
        if let error = msg["jsError"] as? String { NSLog("agents-notch: room page error: \(error.prefix(400))"); return }
        if let awake = msg["awake"] as? Bool { // the other screens' sky moves only while the house does
            houseAwake = awake
            extras.values.forEach { $0.sync(awake: awake) }
            return
        }
        if msg.keys.contains("tip") {
            if let t = msg["tip"] as? [String: Any], let w = window { tip.show(t, in: w.frame) } else { tip.hide() }
            return
        }
        guard let id = msg["open"] as? String,
              let agent = store.shown.first(where: { $0.id == id }) else { return }
        store.open(agent)
    }

    // MARK: mouse

    /// The window ignores the mouse, so the cursor is read globally and passed on while nothing covers the desktop.
    /// Trackpad gestures over bare desktop drive the view: pinch zooms at the cursor, two fingers move, a double tap resets.
    private func mouse(_ type: NSEvent.EventType, magnify: CGFloat = 0, scroll: (CGFloat, CGFloat) = (0, 0)) {
        guard let w = window, let web else { return }
        let p = NSEvent.mouseLocation
        let bare = w.frame.contains(p) && desktopIsBare(at: p)
        let x = p.x - w.frame.minX, y = w.frame.maxY - p.y
        switch type {
        case .leftMouseDown:
            pressed = (p, CACurrentMediaTime())
            return
        case .leftMouseUp:
            // a click, not the end of a drag across the desktop
            let click = pressed.map { hypot($0.0.x - p.x, $0.0.y - p.y) < 6 && CACurrentMediaTime() - $0.1 < 0.6 } ?? true
            pressed = nil
            if bare, click { web.evaluateJavaScript("room.click(\(x), \(y))") }
            return
        case .magnify:
            if bare { web.evaluateJavaScript("room.zoom(\(1 + magnify), \(x), \(y))") }
            else if CACurrentMediaTime() - lastPinchNote > 2 { // why a pinch did not reach the room
                lastPinchNote = CACurrentMediaTime()
                NSLog("agents-notch: pinch not passed on: \(w.frame.contains(p) ? "covered by \(coveringWindow(at: p) ?? "?")" : "outside the wallpaper")")
            }
            return
        case .smartMagnify:
            if bare { web.evaluateJavaScript("room.resetView()") }
            return
        case .scrollWheel:
            if bare, scroll != (0, 0) { web.evaluateJavaScript("room.pan(\(scroll.0), \(scroll.1))") }
            return
        default: break
        }
        let now = CACurrentMediaTime()
        guard now - lastMove > 0.04 else { return }
        lastMove = now
        if bare { hovering = true; web.evaluateJavaScript("room.pointer(\(x), \(y))") }
        else if hovering { hovering = false; tip.hide(); web.evaluateJavaScript("room.leave()") }
    }

    private var lastPinchNote: CFTimeInterval = 0
    /// True when no app window is over this point, so the cursor is over the wallpaper itself.
    private func desktopIsBare(at p: NSPoint) -> Bool { coveringWindow(at: p) == nil }

    /// The app and title of the window over this point, if any (for the log when a gesture is not passed on).
    private func coveringWindow(at p: NSPoint) -> String? {
        guard let primary = NSScreen.screens.first else { return "no screen" }
        let point = CGPoint(x: p.x, y: primary.frame.maxY - p.y)
        let own = window.map { CGWindowID($0.windowNumber) }
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < dock,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  (info[kCGWindowNumber as String] as? CGWindowID) != own,
                  // the Dock lays a clear sheet over the screen while windows are pushed aside to show the desktop
                  (info[kCGWindowOwnerName as String] as? String) != "Dock",
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            if rect.contains(point) { return "\(info[kCGWindowOwnerName as String] as? String ?? "?") layer \(layer) \(rect)" }
        }
        return nil
    }

    // MARK: the page

    /// AGENT_NOTCH_ROOM overrides; the app bundle carries Resources/room; `swift run` finds the repo's room/.
    static var page: URL? {
        if let p = ProcessInfo.processInfo.environment["AGENT_NOTCH_ROOM"] { return URL(fileURLWithPath: p) }
        if let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "room") { return u }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            let c = dir.appendingPathComponent("room/index.html")
            if FileManager.default.fileExists(atPath: c.path) { return c }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

extension RoomWallpaper: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            lastJSON = ""
            sentActive = nil
            sentFps = 0
            sentInsets = nil
            pushRoomConfig()
            push()
            info.resend(store: store)
            syncPower()
        }
    }
}

/// WKUserContentController keeps its handlers alive; this keeps it from keeping the wallpaper alive.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: RoomWallpaper?
    init(_ owner: RoomWallpaper) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { owner?.received(body) }
    }
}

/// The hover card for a Clawd. It is its own window just above the desktop icons, so folders never cover it,
/// and still below every app window.
@MainActor
private final class RoomTip {
    private let panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        return p
    }()

    /// `t` comes from the page: title, status, color, detail and the cursor (x, y) in page points.
    func show(_ t: [String: Any], in frame: NSRect) {
        let view = RoomTipView(title: t["title"] as? String ?? "", status: t["status"] as? String ?? "",
                               color: Color(hex: t["color"] as? String ?? "#aaaaaa"), detail: t["detail"] as? String ?? "")
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host
        let x = (t["x"] as? Double ?? 0), y = (t["y"] as? Double ?? 0)
        var origin = NSPoint(x: frame.minX + x + 16, y: frame.maxY - y - 16 - size.height)
        origin.x = min(origin.x, frame.maxX - size.width - 8)
        if origin.y < frame.minY + 8 { origin.y = frame.maxY - y + 16 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private struct RoomTipView: View {
    let title: String, status: String, color: Color, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status).lineLimit(1)
            }.font(.system(size: 12)).opacity(0.75)
            if !detail.isEmpty { Text(detail).font(.system(size: 12, design: .monospaced)).opacity(0.75).lineLimit(1) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.07, green: 0.06, blue: 0.11).opacity(0.94)))
        .fixedSize()
    }
}

private extension Color {
    init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xaaaaaa
        self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

