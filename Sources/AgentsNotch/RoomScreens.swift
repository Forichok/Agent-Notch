import AppKit
import Combine
import WebKit

/// The house settings reaching a running wallpaper, and the windows on the other screens.
extension RoomWallpaper {
    /// Called from start(): layout and rooms go to the page, the frame rate to every window, the screens get their windows.
    func observeRoomSettings() {
        settingsSubs.removeAll()
        AppSettings.shared.$room
            .removeDuplicates()
            .receive(on: RunLoop.main) // after the change is stored, so syncPower reads the new frame rate
            .sink { [weak self] prefs in
                self?.pushRoomConfig(prefs)
                self?.syncPower()
                self?.syncScreens()
            }
            .store(in: &settingsSubs)
    }

    /// `room.configure({layout, themes})`: the page re-lays out and rebuilds only the rooms whose theme changed.
    func pushRoomConfig(_ prefs: RoomPrefs? = nil) {
        let prefs = prefs ?? AppSettings.shared.room
        web?.evaluateJavaScript("window.room && room.configure && room.configure(\(prefs.pageConfig)); true")
    }

    /// One window on every screen but the main one when «Все экраны» is on; follows screens coming, going and moving.
    func syncScreens() {
        guard isRunning, let page = Self.page else { removeExtras(keepSettings: true); return }
        let others = AppSettings.shared.room.screens == .all ? Array(NSScreen.screens.dropFirst()) : []
        var keep: Set<CGDirectDisplayID> = []
        for screen in others {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            keep.insert(id)
            if let extra = extras[id] { extra.place(on: screen) } else { extras[id] = RoomExtraScreen(screen: screen, page: page, fps: Self.fps, awake: houseAwake) }
        }
        for (id, extra) in extras where !keep.contains(id) { extra.close(); extras[id] = nil }
    }

    func removeExtras(keepSettings: Bool = false) {
        extras.values.forEach { $0.close() }
        extras.removeAll()
        if !keepSettings { settingsSubs.removeAll() }
    }
}

/// A screen next to the main one: the same page with `?scene=extra`, the sky, the city and a few floating islands.
/// It stops drawing whenever its own screen is covered.
@MainActor
final class RoomExtraScreen: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let web: WKWebView
    private var subs: Set<AnyCancellable> = []
    private var fps: Int
    private var sentActive: Bool?
    private var sentFps = 0
    private var awake: Bool
    private var sentAwake: Bool?

    init(screen: NSScreen, page: URL, fps: Int, awake: Bool) {
        self.fps = fps
        self.awake = awake
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.canHide = false
        w.isRestorable = false
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.backgroundColor = .black
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        let web = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: WKWebViewConfiguration())
        web.autoresizingMask = [.width, .height]
        window = w
        self.web = web
        super.init()
        web.navigationDelegate = self
        var url = URLComponents(url: page, resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "nodemo", value: "1"), URLQueryItem(name: "scene", value: "extra"), URLQueryItem(name: "gl", value: "1")]
        web.loadFileURL(url?.url ?? page, allowingReadAccessTo: page.deletingLastPathComponent())
        w.contentView = web
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: w)
            .sink { [weak self] _ in self?.syncPower() }
            .store(in: &subs)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                guard let w = self?.window, !w.isOnActiveSpace else { return }
                w.orderFrontRegardless()
            }
            .store(in: &subs)
    }

    func place(on screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
    }

    func sync(fps: Int) {
        self.fps = fps
        syncPower()
    }

    /// The main screen's house woke up or went still; this screen draws or stands still with it.
    func sync(awake: Bool) {
        self.awake = awake
        syncPower()
    }

    private func syncPower() {
        let visible = window.occlusionState.contains(.visible)
        if visible != sentActive { sentActive = visible; web.evaluateJavaScript("room.setActive(\(visible))") }
        if fps != sentFps { sentFps = fps; web.evaluateJavaScript("room.setFps(\(fps))") }
        if awake != sentAwake { sentAwake = awake; web.evaluateJavaScript("room.setHouseAwake(\(awake))") }
    }

    func close() {
        subs.removeAll()
        web.stopLoading()
        window.orderOut(nil)
        window.contentView = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            sentActive = nil
            sentFps = 0
            sentAwake = nil
            syncPower()
        }
    }
}
