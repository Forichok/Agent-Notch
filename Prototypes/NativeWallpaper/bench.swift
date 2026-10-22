// Research prototype, not part of the app: how much does one active wallpaper frame cost when the
// agents' house is drawn by WebKit (room/index.html) versus natively?
//
//   bench webkit <url>      the real page in a WKWebView, fed with working agents, 60 fps
//   bench count  <url>      the same, but the 2D context counts its calls per frame (costs extra, numbers only)
//   bench stub   <url>      the same JS, but the visible canvas only records commands: the JS half of a hybrid
//   bench cg                a synthetic scene drawn by Core Graphics into a bitmap, shown as layer.contents
//   bench idle              the window alone, nothing drawn
//   bench raw               the same scene written straight into a pixel buffer (a tiny software rasterizer)
//   bench metal             the same scene as one instanced Metal draw into a small drawable
//
// Every mode shows a borderless desktop-level window over the whole main screen (like the wallpaper) and
// draws at art-pixel scale: the drawing surface is screen/3 and the layer upscales it nearest-neighbour.
// The process measures itself: after a warm-up it samples `ps` CPU time of this process, of the WebKit
// processes that appeared after launch, and of WindowServer, then again after the measuring window.
// Env: RECTS (small fills per frame, default 7000), BIG (large image draws, default 110), SPRITES (small image draws,
// default 140), SECS (default 30), WARM (default 6). The defaults match what `bench count` measured on the real
// page with eight working agents: ~7300 fillRect, ~250 drawImage of which ~110 cover ~36k px each.
import AppKit
import WebKit
import Metal
import QuartzCore

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "cg"
let env = ProcessInfo.processInfo.environment
let RECTS = Int(env["RECTS"] ?? "") ?? 7000
let SPRITES = Int(env["SPRITES"] ?? "") ?? 140
let BIG = Int(env["BIG"] ?? "") ?? 110
let SECS = Double(env["SECS"] ?? "") ?? 30
let WARM = Double(env["WARM"] ?? "") ?? 6
let SCALE = 3

// ---------- measuring ----------
func psTimes(_ pids: [Int32]) -> [Int32: Double] {
    guard !pids.isEmpty else { return [:] }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "pid=,time=", "-p", pids.map(String.init).joined(separator: ",")]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    var out: [Int32: Double] = [:]
    for line in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true); guard f.count == 2, let pid = Int32(f[0]) else { continue }
        // [[hh:]mm:]ss.cc
        var s = 0.0; for part in f[1].split(separator: ":") { s = s * 60 + (Double(part) ?? 0) }
        out[pid] = s
    }
    return out
}
// GPU busy share as the driver reports it (whole machine, so the other apps' share is in it too)
func gpuUtil() -> Double? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-r", "-d", "1", "-w", "0", "-c", "AGXAccelerator"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard let r = s.range(of: "\"Device Utilization %\"=") else { return nil }
    return Double(s[r.upperBound...].prefix { $0.isNumber })
}
func pidsMatching(_ pattern: String) -> [Int32: String] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,comm="]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    var out: [Int32: String] = [:]
    for line in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces); guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
        let comm = String(t[sp...]).trimmingCharacters(in: .whitespaces)
        if comm.range(of: pattern, options: .regularExpression) != nil { out[pid] = (comm as NSString).lastPathComponent }
    }
    return out
}
let webkitBefore = Set(pidsMatching("com.apple.WebKit").keys)
let windowServer = pidsMatching("WindowServer$").keys.first ?? 0

final class Meter {
    var frames = 0
    var t0 = 0.0, f0 = 0, a: [Int32: Double] = [:], pids: [Int32: String] = [:]
    var extra: () -> String = { "" }
    var onStart: () -> Void = {}
    var gpu: [Double] = []
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + WARM) { [self] in
            pids = [getpid(): "bench (\(mode))", windowServer: "WindowServer"]
            for (pid, name) in pidsMatching("com.apple.WebKit") where !webkitBefore.contains(pid) { pids[pid] = name }
            a = psTimes(Array(pids.keys)); t0 = CACurrentMediaTime(); f0 = frames; onStart()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in if let g = gpuUtil() { gpu.append(g) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + SECS) { [self] in finish() }
        }
    }
    var beforeReport: ((@escaping (String) -> Void) -> Void)?  // e.g. read a result out of the page first
    func finish() {
        guard let pre = beforeReport else { return report("") }
        pre { [self] in report($0) }
    }
    func report(_ note: String) {
        if !note.isEmpty { print("PAGE " + note) }
        let b = psTimes(Array(pids.keys)), dt = CACurrentMediaTime() - t0, fps = Double(frames - f0) / dt
        var lines: [String] = [], appTotal = 0.0, ws = 0.0
        for (pid, name) in pids.sorted(by: { $0.key < $1.key }) {
            let pct = ((b[pid] ?? 0) - (a[pid] ?? 0)) / dt * 100
            if pid == windowServer { ws = pct } else { appTotal += pct }
            lines.append(String(format: "  %-34@ %6.1f%%", name as NSString, pct))
        }
        let visible = win.occlusionState.contains(.visible)
        print(String(format: "RESULT mode=%@ rects=%d big=%d sprites=%d secs=%.0f fps=%.1f visible=%@ app=%.1f%% windowserver=%.1f%% gpu=%.0f%%%@",
                     mode, RECTS, BIG, SPRITES, dt, fps, visible ? "yes" : "no", appTotal, ws, gpu.reduce(0, +) / Double(max(1, gpu.count)), extra()))
        lines.forEach { print($0) }
        fflush(stdout); exit(0)
    }
}
let meter = Meter()

// ---------- window ----------
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
// LEVEL=desktop puts it where the wallpaper lives; by default it floats above everything (click-through), because
// a covered window gets its frames throttled and the numbers would mean nothing.
win.level = env["LEVEL"] == "desktop" ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow))) : .floating
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
win.ignoresMouseEvents = true; win.isOpaque = true; win.backgroundColor = .black; win.hasShadow = false
win.isReleasedWhenClosed = false
let W = Int(ceil(screen.frame.width / CGFloat(SCALE))), H = Int(ceil(screen.frame.height / CGFloat(SCALE)))

// ---------- the synthetic scene, shared by every native mode ----------
// Plain value types so each backend draws exactly the same thing.
struct RGBA { var r, g, b, a: UInt8; var u32: UInt32 { UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24 } }
struct Pixmap { let w, h: Int; var px: [UInt32] }  // premultiplied RGBA8, row 0 at the top

var rng = SystemRandomNumberGenerator()
func rnd(_ n: Int) -> Int { Int.random(in: 0..<max(1, n), using: &rng) }

// Large static layers, stand-ins for the baked rooms: an isometric-ish block with outlines and some detail.
func makeLayer(_ w: Int, _ h: Int, seed: Int) -> Pixmap {
    var p = Pixmap(w: w, h: h, px: .init(repeating: 0, count: w * h))
    let base = [RGBA(r: 200, g: 170, b: 140, a: 255), RGBA(r: 150, g: 180, b: 200, a: 255), RGBA(r: 190, g: 150, b: 190, a: 255)][seed % 3]
    for y in 0..<h { for x in 0..<w {
        let inside = abs(x - w / 2) * 2 + y >= w / 2 && abs(x - w / 2) * 2 <= w - 2 // a diamond-topped tower
        guard inside else { continue }
        let shade: Double = x < w / 2 ? 0.86 : 0.72, top = y < w / 2 ? 1.0 : shade
        let k = ((x / 4 + y / 4 + seed) % 7 == 0) ? 0.8 : top
        p.px[y * w + x] = RGBA(r: UInt8(Double(base.r) * k), g: UInt8(Double(base.g) * k), b: UInt8(Double(base.b) * k), a: 255).u32
    } }
    return p
}
func makeSprite(_ i: Int) -> Pixmap {
    let w = 10, h = 14; var p = Pixmap(w: w, h: h, px: .init(repeating: 0, count: w * h))
    let body = i % 2 == 0 ? RGBA(r: 222, g: 120, b: 80, a: 255) : RGBA(r: 90, g: 90, b: 220, a: 255)
    for y in 0..<h { for x in 0..<w where (y > 2 || (x > 2 && x < 7)) && !(y > 11 && (x == 4 || x == 5)) {
        p.px[y * w + x] = (x == 0 || x == w - 1 || y == h - 1) ? RGBA(r: 42, g: 31, b: 46, a: 255).u32 : body.u32
    } }
    p.px[5 * w + 3] = RGBA(r: 0, g: 0, b: 0, a: 255).u32; p.px[5 * w + 6] = RGBA(r: 0, g: 0, b: 0, a: 255).u32
    return p
}
let layers: [Pixmap] = (0..<6).map { i in makeLayer(170 + (i % 3) * 20, 170 + (i % 2) * 40, seed: i) }
let spriteImgs = (0..<16).map(makeSprite)  // drawn SPRITES times per frame, round robin
let palette: [RGBA] = (0..<32).map { (i: Int) -> RGBA in
    let r: Int = 60 + i * 6, g: Int = 200 - i * 4, b: Int = 90 + (i * 37) % 160
    return RGBA(r: UInt8(r), g: UInt8(g), b: UInt8(b), a: 255)
}

// Per frame: where sprites stand and the small dynamic rects (1..3 px, like poly spans, pixels, glints).
struct Rect { var x, y, w, h: Int; var c: Int }
var spritePos: [(Int, Int)] = []
var bigPos: [(Int, Int, Int)] = []  // (layer, x, y): rooms, islands, backdrop pieces; they drift with the camera
var rects: [Rect] = []
func step(_ t: Double) {
    spritePos = (0..<SPRITES).map { i in
        let a = t * (0.4 + Double(i % 5) * 0.1) + Double(i)
        return (Int(Double(W / 2) + cos(a) * Double(W / 3)), Int(Double(H / 2) + sin(a * 1.3) * Double(H / 4)))
    }
    bigPos = (0..<BIG).map { i in
        let l = layers[i % layers.count], drift = Int(sin(t * 0.2 + Double(i)) * 3)
        return (i % layers.count, (i * 97) % (W - l.w / 2) - l.w / 4 + drift, (i * 53) % (H - l.h / 2) - l.h / 4)
    }
    rects.removeAll(keepingCapacity: true)
    for i in 0..<RECTS {
        let a = t * 0.7 + Double(i) * 0.013
        rects.append(Rect(x: (i * 37 + Int(t * 20)) % W, y: Int(Double(H) * 0.15) + (i * 13 + Int(sin(a) * 6)) % Int(Double(H) * 0.8),
                          w: 1 + i % 3, h: i % 4 == 0 ? 2 : 1, c: i % palette.count))
    }
}
func skyColor(_ y: Int, _ t: Double) -> RGBA {
    let k = Double(y) / Double(H), s = 0.5 + 0.5 * sin(t * 0.05)
    return RGBA(r: UInt8(140 + 88 * k * s), g: UInt8(196 + 44 * k), b: UInt8(244 - 4 * k), a: 255)
}

// ---------- backends ----------
protocol Backend { func draw(_ t: Double) }

/// Core Graphics: a bitmap context at art-pixel size; each frame becomes a CGImage on layer.contents.
final class CGBackend: Backend {
    let layer: CALayer, ctx: CGContext, layerImgs: [CGImage], spriteCG: [CGImage]
    let colors: [CGColor]
    init(view: NSView) {
        view.wantsLayer = true; layer = view.layer!
        layer.magnificationFilter = .nearest; layer.contentsGravity = .resize
        ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none; ctx.setShouldAntialias(false)
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1) // top-left origin, like canvas
        func img(_ p: Pixmap) -> CGImage {
            let data = p.px.withUnsafeBytes { Data($0) } as CFData
            return CGImage(width: p.w, height: p.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.w * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        layerImgs = layers.map(img); spriteCG = spriteImgs.map(img)
        colors = palette.map { CGColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1) }
    }
    func drawImage(_ i: CGImage, _ x: Int, _ y: Int) {
        // images are stored top-down; flip back locally so they aren't upside down
        ctx.saveGState(); ctx.translateBy(x: CGFloat(x), y: CGFloat(y + i.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height)); ctx.restoreGState()
    }
    func draw(_ t: Double) {
        for y in 0..<H { let c = skyColor(y, t); ctx.setFillColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: W, height: 1)) }
        for b in bigPos { drawImage(layerImgs[b.0], b.1, b.2) }
        for (i, p) in spritePos.enumerated() { drawImage(spriteCG[i % 16], p.0, p.1) }
        for r in rects { ctx.setFillColor(colors[r.c]); ctx.fill(CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = ctx.makeImage(); CATransaction.commit()
    }
}

/// A tiny software rasterizer: fills and blits are plain loops over a UInt32 buffer, which is what
/// pixel art needs (no antialiasing, no transforms). The frame goes up as a CGImage too.
final class RawBackend: Backend {
    let layer: CALayer; var buf: Pixmap; let colors: [UInt32]
    init(view: NSView) {
        view.wantsLayer = true; layer = view.layer!
        layer.magnificationFilter = .nearest; layer.contentsGravity = .resize
        buf = Pixmap(w: W, h: H, px: .init(repeating: 0, count: W * H)); colors = palette.map(\.u32)
    }
    @inline(__always) func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ c: UInt32, _ p: UnsafeMutablePointer<UInt32>) {
        let x1 = min(W, x0 + w), y1 = min(H, y0 + h), xs = max(0, x0)
        guard xs < x1 else { return }
        for y in max(0, y0)..<max(max(0, y0), y1) { (p + y * W + xs).update(repeating: c, count: x1 - xs) }
    }
    @inline(__always) func blit(_ s: Pixmap, _ x0: Int, _ y0: Int, _ p: UnsafeMutablePointer<UInt32>) {
        s.px.withUnsafeBufferPointer { sp in
            for sy in 0..<s.h { let y = y0 + sy; guard y >= 0 && y < H else { continue }
                for sx in 0..<s.w { let x = x0 + sx; guard x >= 0 && x < W else { continue }
                    let v = sp[sy * s.w + sx]; if v >> 24 != 0 { p[y * W + x] = v } } }
        }
    }
    func draw(_ t: Double) {
        buf.px.withUnsafeMutableBufferPointer { bp in
            let p = bp.baseAddress!
            for y in 0..<H { fill(0, y, W, 1, skyColor(y, t).u32, p) }
            for b in bigPos { blit(layers[b.0], b.1, b.2, p) }
            for (i, s) in spritePos.enumerated() { blit(spriteImgs[i % 16], s.0, s.1, p) }
            for r in rects { fill(r.x, r.y, r.w, r.h, colors[r.c], p) }
        }
        let data = buf.px.withUnsafeBytes { Data($0) } as CFData
        let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.contents = img; CATransaction.commit()
    }
}

/// Metal: one texture atlas (layers, sprites, a white texel for fills), every rect, layer and sprite an
/// instance of one quad; one draw call per frame into a drawable the size of the art canvas.
final class MetalBackend: Backend {
    struct Inst { var dst: SIMD4<Float>; var uv: SIMD4<Float>; var color: SIMD4<Float> }
    let dev = MTLCreateSystemDefaultDevice()!, layer = CAMetalLayer(), queue: MTLCommandQueue, pipe: MTLRenderPipelineState
    let atlas: MTLTexture, slots: [SIMD4<Float>]  // uv rect per image: layers first, then sprites, then the white texel
    var instBufs: [MTLBuffer] = [], bufIdx = 0
    let sem = DispatchSemaphore(value: 3)
    init(view: NSView) {
        layer.device = dev; layer.pixelFormat = .bgra8Unorm; layer.framebufferOnly = true
        layer.drawableSize = CGSize(width: W, height: H); layer.magnificationFilter = .nearest; layer.contentsGravity = .resize
        layer.isOpaque = true; layer.maximumDrawableCount = 3
        view.wantsLayer = true; view.layer = layer
        queue = dev.makeCommandQueue()!
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct Inst { float4 dst; float4 uv; float4 color; };
        struct VO { float4 pos [[position]]; float2 uv; float4 color; };
        vertex VO vmain(uint v [[vertex_id]], uint i [[instance_id]], const device Inst* inst [[buffer(0)]], constant float2& size [[buffer(1)]]) {
            float2 c = float2(v & 1, v >> 1); Inst s = inst[i];
            float2 p = s.dst.xy + c * s.dst.zw; VO o;
            o.pos = float4(p.x / size.x * 2 - 1, 1 - p.y / size.y * 2, 0, 1);
            o.uv = s.uv.xy + c * s.uv.zw; o.color = s.color; return o;
        }
        fragment float4 fmain(VO in [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler sm(filter::nearest);
            float4 c = t.sample(sm, in.uv) * in.color; if (c.a == 0) discard_fragment(); return c;
        }
        """
        let lib = try! dev.makeLibrary(source: src, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vmain"); d.fragmentFunction = lib.makeFunction(name: "fmain")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        d.colorAttachments[0].isBlendingEnabled = true // premultiplied source-over, like canvas
        d.colorAttachments[0].sourceRGBBlendFactor = .one; d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .one; d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipe = try! dev.makeRenderPipelineState(descriptor: d)
        // pack everything in one row-shelf atlas
        let imgs = layers + spriteImgs + [Pixmap(w: 1, h: 1, px: [0xFFFF_FFFF])]
        let AW = 1024; var x = 0, y = 0, rowH = 0, places: [(Int, Int)] = []
        for p in imgs { if x + p.w > AW { x = 0; y += rowH; rowH = 0 }; places.append((x, y)); x += p.w; rowH = max(rowH, p.h) }
        let AH = y + rowH
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: AW, height: AH, mipmapped: false)
        let atlas = dev.makeTexture(descriptor: td)!
        self.atlas = atlas
        var s: [SIMD4<Float>] = []
        for (p, pl) in zip(imgs, places) {
            p.px.withUnsafeBytes { atlas.replace(region: MTLRegionMake2D(pl.0, pl.1, p.w, p.h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: p.w * 4) }
            s.append(SIMD4(Float(pl.0) / Float(AW), Float(pl.1) / Float(AH), Float(p.w) / Float(AW), Float(p.h) / Float(AH)))
        }
        slots = s
        let cap = (H + BIG + SPRITES + RECTS) * MemoryLayout<Inst>.stride
        instBufs = (0..<3).map { _ in dev.makeBuffer(length: cap, options: .storageModeShared)! }
    }
    func draw(_ t: Double) {
        guard sem.wait(timeout: .now()) == .success else { return } // GPU behind: skip rather than queue
        guard let drawable = layer.nextDrawable() else { sem.signal(); return }
        let buf = instBufs[bufIdx]; bufIdx = (bufIdx + 1) % 3
        let p = buf.contents().bindMemory(to: Inst.self, capacity: buf.length / MemoryLayout<Inst>.stride)
        var n = 0, white = slots.last!
        white.z = 0; white.w = 0 // sample the single texel's corner
        func put(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ uv: SIMD4<Float>, _ c: SIMD4<Float>) {
            p[n] = Inst(dst: SIMD4(Float(x), Float(y), Float(w), Float(h)), uv: uv, color: c); n += 1
        }
        for y in 0..<H { let c = skyColor(y, t); put(0, y, W, 1, white, SIMD4(Float(c.r), Float(c.g), Float(c.b), 255) / 255) }
        let one = SIMD4<Float>(1, 1, 1, 1)
        for b in bigPos { put(b.1, b.2, layers[b.0].w, layers[b.0].h, slots[b.0], one) }
        for (i, s) in spritePos.enumerated() { put(s.0, s.1, spriteImgs[i % 16].w, spriteImgs[i % 16].h, slots[layers.count + i % 16], one) }
        for r in rects { let c = palette[r.c]; put(r.x, r.y, r.w, r.h, white, SIMD4(Float(c.r), Float(c.g), Float(c.b), 255) / 255) }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture; rp.colorAttachments[0].loadAction = .dontCare; rp.colorAttachments[0].storeAction = .store
        let cb = queue.makeCommandBuffer()!, enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipe); enc.setVertexBuffer(buf, offset: 0, index: 0)
        var size = SIMD2<Float>(Float(W), Float(H)); enc.setVertexBytes(&size, length: 8, index: 1)
        enc.setFragmentTexture(atlas, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        enc.endEncoding()
        let sem = self.sem; cb.addCompletedHandler { _ in sem.signal() }
        cb.present(drawable); cb.commit()
    }
}

final class Ticker: NSObject {
    let backend: Backend; let t0 = CACurrentMediaTime()
    init(_ b: Backend) { backend = b }
    @objc func tick(_ link: CADisplayLink) {
        let t = CACurrentMediaTime() - t0
        step(t); backend.draw(t); meter.frames += 1
    }
}

// ---------- WebKit baseline ----------
final class Page: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var counts: [String: Double] = [:], countFrames = 0.0
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any] else { return }
        if let f = d["frames"] as? Double { meter.frames = Int(f) }
        if let c = d["counts"] as? [String: Double], let n = d["n"] as? Double { counts = c; countFrames = n }
    }
    func webView(_ web: WKWebView, didFinish nav: WKNavigation!) {
        // working agents in three projects, so rooms are busy and Clawds walk between them
        let agents = (0..<8).map { i in
            "{id:'a\(i)',title:'task \(i)',project:'\(["Agent-Notch", "hexhaven", "world"][i % 3])',vendor:'\(i % 3 == 1 ? "codex" : "claude")',state:'working',activity:'Bash · swift build',parentId:\(i >= 6 ? "'a0'" : "null"),model:'opus',ask:null,age:1}"
        }.joined(separator: ",")
        web.evaluateJavaScript("room.setFps(60); room.setAgents([\(agents)]);")
    }
}
// rAF counter (cheap) and, for `count`, a per-call tally on every 2D context
let frameCounter = """
let __f = 0; (function tick() { __f++; requestAnimationFrame(tick); })();
setInterval(() => window.webkit.messageHandlers.bench.postMessage({frames: __f}), 250);
"""
let callCounter = """
(() => { // own scope: the page has globals of its own (main, P...)
const __c = {}; let __n = 0, __pix = 0, __img = 0;
const P = CanvasRenderingContext2D.prototype;
for (const k of ['fillRect','clearRect','drawImage','fillText','fill','stroke','putImageData','createLinearGradient','save','restore','setTransform','beginPath'])
  if (P[k]) { const f = P[k]; P[k] = function(...a) { __c[k] = (__c[k] || 0) + 1;
    const off = this.canvas !== document.querySelector('canvas'); if (off) __c.offscreenCalls = (__c.offscreenCalls || 0) + 1;
    if (this.globalAlpha < 1 && (k === 'fillRect' || k === 'drawImage')) __c.alphaOps = (__c.alphaOps || 0) + 1;
    if (k === 'fillRect') { const ar = Math.abs(a[2] * a[3]); __pix += ar; if (ar >= 4000) { __c.bigFill = (__c.bigFill || 0) + 1; __c.bigFillPx = (__c.bigFillPx || 0) + ar; } }
    if (k === 'drawImage') { const ar = a.length >= 9 ? a[7] * a[8] : a.length >= 5 ? a[3] * a[4] : (a[0].width * a[0].height); __img += ar;
      if (ar >= 4000) { __c.bigImg = (__c.bigImg || 0) + 1; __c.bigImgPx = (__c.bigImgPx || 0) + ar; } }
    return f.apply(this, a); }; }
const fs = Object.getOwnPropertyDescriptor(P, 'fillStyle');
Object.defineProperty(P, 'fillStyle', { get() { return fs.get.call(this); }, set(v) { __c.fillStyleSet = (__c.fillStyleSet || 0) + 1; fs.set.call(this, v); } });
(function tick() { __n++; requestAnimationFrame(tick); })();
setInterval(() => { const o = Object.assign({}, __c, {fillRectPixels: __pix, drawImagePixels: __img});
  window.webkit.messageHandlers.bench.postMessage({counts: o, n: __n}); }, 500);
})();
"""

// `stub`: what the JS half of a hybrid would cost. The page runs as usual, but calls on the visible canvas only
// append to a command buffer (as a JavaScriptCore shim feeding a native renderer would) and nothing is drawn.
let stubRecorder = """
(() => { // own scope: the page has globals of its own (main, P...)
const __buf = new Float32Array(1 << 20), __styles = new Map(); let __i = 0, __n = 0, __cmds = 0;
let __main = null; const P = CanvasRenderingContext2D.prototype, main = () => __main || (__main = document.querySelector('canvas'));
const sid = v => { let k = __styles.get(v); if (k === undefined) { k = __styles.size; __styles.set(v, k); } return k; };
const real = {}; for (const k of ['fillRect','drawImage','clearRect','fill','arc','beginPath','moveTo','lineTo','closePath','save','restore','translate','scale','setTransform']) real[k] = P[k];
const fs = Object.getOwnPropertyDescriptor(P, 'fillStyle');
Object.defineProperty(P, 'fillStyle', { get() { return this.__fs ?? fs.get.call(this); }, set(v) { if (this.canvas === main()) this.__fs = v; else fs.set.call(this, v); } });
const put = (op, a, b, c, d, e) => { if (__i > __buf.length - 8) __i = 0; __buf[__i++] = op; __buf[__i++] = a; __buf[__i++] = b; __buf[__i++] = c; __buf[__i++] = d; __buf[__i++] = e; __cmds++; };
P.fillRect = function(x, y, w, h) { if (this.canvas !== main()) return real.fillRect.call(this, x, y, w, h); put(1, x, y, w, h, sid(this.__fs)); };
P.drawImage = function(im, ...a) { if (this.canvas !== main()) return real.drawImage.call(this, im, ...a); put(2, a[0], a[1], a[2] || 0, a[3] || 0, sid(im)); };
for (const k of ['clearRect','fill','arc','beginPath','moveTo','lineTo','closePath','save','restore','translate','scale','setTransform'])
  P[k] = function(...a) { if (this.canvas !== main()) return real[k].apply(this, a); put(3, 0, 0, 0, 0, 0); };
(function tick() { __n++; __i = 0; requestAnimationFrame(tick); })();
setInterval(() => window.webkit.messageHandlers.bench.postMessage({counts: {recorded: __cmds}, n: __n}), 500);
})();
"""

let page = Page()
var keep: [AnyObject] = []
let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
win.contentView = view

switch mode {
case "webkit", "count", "stub":
    let url = args.count > 2 ? args[2] : "http://127.0.0.1:8765/index.html?nodemo=1"
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.add(page, name: "bench")
    cfg.userContentController.addUserScript(WKUserScript(source: frameCounter, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    if mode == "stub" {
        cfg.userContentController.addUserScript(WKUserScript(source: stubRecorder, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    if mode == "count" || mode == "stub" {
        if mode == "count" { cfg.userContentController.addUserScript(WKUserScript(source: callCounter, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        // only the steady state counts: the start (baking every room) is left out
        var c0: [String: Double] = [:], n0 = 0.0
        meter.onStart = { c0 = page.counts; n0 = page.countFrames }
        meter.extra = {
            let n = max(1, page.countFrames - n0)
            return " | per frame: " + page.counts.sorted { $0.key < $1.key }.map { String(format: "%@=%.0f", $0.key, ($0.value - (c0[$0.key] ?? 0)) / n) }.joined(separator: " ")
        }
    }
    let web = WKWebView(frame: view.bounds, configuration: cfg)
    web.navigationDelegate = page
    web.load(URLRequest(url: URL(string: url)!))
    win.contentView = web
    keep.append(web)
    // `bench webkit <…/gl-diff.html?…>`: print the frame-by-frame comparison of WebGL and 2D at the end
    if url.contains("gl-diff.html") {
        meter.beforeReport = { done in web.evaluateJavaScript("JSON.stringify(window.DIFF)") { r, _ in done((r as? String) ?? "no DIFF") } }
    }
case "idle": // the window alone, nothing drawn: the floor WindowServer and the process sit on
    view.wantsLayer = true; view.layer?.backgroundColor = NSColor.systemTeal.cgColor
default:
    let backend: Backend
    switch mode { case "metal": backend = MetalBackend(view: view); case "raw": backend = RawBackend(view: view); default: backend = CGBackend(view: view) }
    let ticker = Ticker(backend); keep.append(ticker)
    let link = view.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    keep.append(link)
}
win.setFrame(screen.frame, display: true)
win.orderFrontRegardless()
print("art canvas \(W)x\(H), screen \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt @\(screen.backingScaleFactor)x, mode \(mode)")
meter.start()
app.run()
