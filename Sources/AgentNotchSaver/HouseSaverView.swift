import AppKit
import NotchCore
import ScreenSaver
import WebKit

/// The agents' house as a screen saver: room/index.html in a WKWebView, fed from the snapshot the running app writes
/// (HouseSnapshot), polled every `poll` seconds. With "Require password immediately" it works as a live lock screen.
///
/// Since Sonoma the saver runs in legacyScreenSaver, which keeps old views alive: stopAnimation is often never called,
/// every start makes a new view, and the process outlives the saver. So the views tear themselves down on the
/// `com.apple.screensaver.willstop` notification too, a WebContent process that died is reloaded, and once the saver
/// has stopped with no preview left the process quits, so the next start begins clean. Its window is also drawn
/// off screen, so WebKit would treat the page as hidden and never draw it (see makeWeb).
@objc(AgentNotchHouseView)
final class HouseSaverView: ScreenSaverView {
    static let poll: TimeInterval = 2

    private var web: WKWebView?
    private var timer: Timer?
    private var loaded = false
    private var shown: HouseSnapshot?
    private var observers: [NSObjectProtocol] = []
    private let file = HouseSnapshot.url(home: HouseSnapshot.realHome)
    private static let views = NSHashTable<HouseSaverView>.weakObjects()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        Self.views.add(self)
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screensaver.willstop"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saverWillStop() }
        })
        log("init \(isPreview ? "preview" : "screen") \(frame.size)")
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
    override func animateOneFrame() {}
    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func startAnimation() {
        super.startAnimation()
        log("start")
        if web == nil { makeWeb() } else if !loaded { reload() }
        timer?.invalidate()
        let t = Timer(timeInterval: Self.poll, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        send("room.setActive(true)")
        refresh()
    }

    override func stopAnimation() {
        super.stopAnimation()
        log("stop")
        tearDown()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tearDown() }
    }

    /// The saver stopped: legacyScreenSaver may never call stopAnimation, so every view lets go of its page here.
    private func saverWillStop() {
        log("willstop")
        tearDown()
        guard !isPreview else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // A process left running keeps stale views around and sometimes shows a black screen on the next start.
            let previews = Self.views.allObjects.contains { $0.isPreview && $0.window != nil }
            if !previews, Bundle.main.bundleIdentifier?.contains("legacyScreenSaver") == true {
                NSLog("agent-notch-house: exiting legacyScreenSaver after the saver stopped")
                exit(0)
            }
        }
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        guard let web else { return }
        web.navigationDelegate = nil
        web.stopLoading()
        web.removeFromSuperview()
        self.web = nil
        loaded = false
        shown = nil
    }

    // MARK: the page

    private func makeWeb() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        // The saver's window is drawn off screen and shown by ScreenSaverEngine, so WebKit sees it as covered,
        // marks the page hidden and stops its frames: the screen stays the page's empty background.
        for (sel, on) in [("_setHiddenPageDOMTimerThrottlingEnabled:", false), ("_setHiddenPageCSSAnimationSuspensionEnabled:", false),
                          ("_setPageVisibilityBasedProcessSuppressionEnabled:", false)] {
            Self.set(config.preferences, sel, on)
        }
        config.userContentController.addUserScript(WKUserScript(source: Self.frameClock, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: bounds, configuration: config)
        Self.set(web, "_setWindowOcclusionDetectionEnabled:", false)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        self.web = web
        reload()
    }

    private func reload() {
        guard let web else { return }
        loaded = false
        shown = nil
        guard let page = Bundle(for: HouseSaverView.self).url(forResource: "index", withExtension: "html", subdirectory: "room") else {
            log("room/index.html is missing from the bundle")
            return
        }
        var url = URLComponents(url: page, resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "nodemo", value: "1")]
        web.loadFileURL(url?.url ?? page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    /// Sends the house in the snapshot file when it changed; a missing or stale file is an empty house.
    private func refresh() {
        guard loaded else { return }
        let now = Date()
        let next = (try? Data(contentsOf: file)).flatMap { HouseSnapshot.decode($0, now: now) } ?? .empty(at: now)
        let old = shown
        shown = next
        if old?.config != next.config { send("room.configure && room.configure(\(next.config))") }
        if old?.fps != next.fps { send("room.setFps(\(next.fps))") }
        if old?.agents != next.agents { send("room.setAgents(\(next.agents))") }
        if let usage = next.usage, old?.usage != usage { send("room.setUsage(\(usage))") }
    }

    private func send(_ js: String) {
        guard loaded, let web else { return }
        web.evaluateJavaScript("window.room && (\(js)); true") { [weak self] _, error in
            if let error { MainActor.assumeIsolated { self?.log("page call failed: \(error.localizedDescription)") } }
        }
    }

    /// Calls a WebKit setter that takes a BOOL, if this macOS has it.
    private static func set(_ object: NSObject, _ name: String, _ value: Bool) {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel), let method = class_getInstanceMethod(type(of: object), sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, sel, value)
    }

    /// While the page is hidden its animation frames never come, so frames are paced by a timer instead.
    private static let frameClock = """
    (() => {
      const raf = window.requestAnimationFrame.bind(window), caf = window.cancelAnimationFrame.bind(window), timers = new Map();
      let next = 1e9;
      window.requestAnimationFrame = cb => {
        if (document.visibilityState === 'visible') return raf(cb);
        const id = next++;
        timers.set(id, setTimeout(() => { timers.delete(id); cb(performance.now()); }, 1000 / 60));
        return id;
      };
      window.cancelAnimationFrame = id => { if (timers.has(id)) { clearTimeout(timers.get(id)); timers.delete(id); } else caf(id); };
    })();
    """

    /// Logs whether the page is drawing: what WebKit thinks of its visibility and how many frames it got in a second.
    private func diagnose() {
        guard let web else { return }
        let occl = window.map { $0.occlusionState.contains(.visible) ? "visible" : "occluded" } ?? "no window"
        let js = """
        return await new Promise(r => { let n = 0; const t0 = performance.now();
          const f = () => { n++; if (performance.now() - t0 < 1000) requestAnimationFrame(f); else r(n); };
          requestAnimationFrame(f); setTimeout(() => r('stalled at ' + n), 2500); })
          .then(n => JSON.stringify({vis: document.visibilityState, raf: n, w: innerWidth, h: innerHeight}));
        """
        web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            let text = (try? result.get()).map { "\($0)" } ?? "error"
            MainActor.assumeIsolated { self?.log("diagnose window=\(occl) page=\(text)") }
        }
    }

    private func log(_ message: String) { NSLog("agent-notch-house: \(message)") }
}

extension HouseSaverView: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard webView === web else { return }
            loaded = true
            shown = nil
            log("page loaded")
            // nothing covers the screen saver: no menu bar, no Dock, no desktop icons
            send("room.setInsets({top: 0, bottom: 0, right: 0})")
            send("room.setActive(true)")
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.diagnose() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { log("page failed: \(error.localizedDescription)") }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { log("page failed to open: \(error.localizedDescription)") }
    }

    /// The system may kill the page's process while the saver runs; a black screen would stay until the next start.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard webView === web else { return }
            log("page process ended, reloading")
            reload()
        }
    }
}
