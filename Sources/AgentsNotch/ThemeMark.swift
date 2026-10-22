import SwiftUI
import NotchCore

/// Every theme draws agents its own way; the meaning stays the same everywhere:
/// one shape per vendor, hollow or thin for light models, colour or glyph for the state.
/// «Терминал» keeps the mark style chosen in settings.
struct ThemeMark: View {
    let theme: Theme
    let vendor: Vendor
    let state: AgentState
    let isLight: Bool
    let size: CGFloat
    /// The wing is always black: themes made for light surfaces borrow the terminal's state colours there.
    var onDark = false
    /// A mark borrowed from a dark theme onto a light surface takes Paper's state colours, the mirror of `onDark`.
    var onLight = false

    var body: some View {
        Group {
            if animates {
                SurfaceTimeline(every: interval) { date in
                    let t = date.timeIntervalSinceReferenceDate
                    mark(t: t)
                        .opacity(state == .waiting && blinks ? (Int(t * 2) % 2 == 0 ? 1 : 0.35) : 1)
                }
            } else {
                mark(t: 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel((vendor == .claude ? SettingsText.claude : SettingsText.codex) + ", " + SettingsText.name(stateKey))
    }

    private var claude: Bool { vendor == .claude }
    private var stateKey: String {
        switch state { case .working: "working"; case .waiting: "waiting"; case .error: "error"; case .done: "done" }
    }
    private var ink: Color {
        if onDark && theme.scheme == .light { return Theme.terminal.color(role) }
        if onLight && theme.scheme == .dark { return Theme.paper.color(role) }
        return theme.color(role)
    }
    /// Only marks that move get a timeline; a still mark costs nothing while the wing sits on screen.
    private var animates: Bool {
        switch state {
        case .waiting: true
        case .working: [ThemeID.midnight, .phosphor, .hologram, .wasteland, .pixel, .ducks].contains(theme.id)
        case .error, .done: false
        }
    }
    /// A blink or a two-frame glyph changes twice a second; only marks in motion need the fast clock.
    private var interval: TimeInterval { state == .waiting && theme.id != .midnight ? 0.5 : 0.12 }
    private var role: InkRole {
        switch state { case .working: .working; case .waiting: .waiting; case .error: .error; case .done: .dim }
    }
    /// Marks that already change shape for «ждёт» do not blink on top of it.
    private var blinks: Bool { ![ThemeID.phosphor, .wasteland, .midnight].contains(theme.id) }

    @ViewBuilder private func mark(t: Double) -> some View {
        switch theme.id {
        case .terminal: EmptyView()
        case .glass: bead
        case .paper: initial
        case .midnight: linearStatus(t: t)
        case .console: led
        case .phosphor: spinner(t: t)
        case .synthwave: neon
        case .blueprint: drafting
        case .brutal: sticker
        case .hologram: prism(t: t)
        case .wasteland: pixels(t: t)
        case .pixel: sprite(t: t)
        case .ducks: duck(t: t)
        }
    }

    // MARK: glass — a bead of coloured glass with a highlight

    private var bead: some View {
        let shape = claude ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
        return ZStack {
            if isLight {
                shape.stroke(ink.opacity(0.95), lineWidth: max(1.2, size * 0.18))
            } else {
                shape.fill(RadialGradient(colors: [ink.opacity(0.95), ink.opacity(0.55)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.8))
                shape.stroke(.white.opacity(0.45), lineWidth: 0.5)
            }
            Ellipse().fill(.white.opacity(0.85)).frame(width: size * 0.32, height: size * 0.2).offset(x: -size * 0.14, y: -size * 0.2).blur(radius: 0.3)
        }
        .shadow(color: ink.opacity(0.6), radius: size * 0.3)
    }

    // MARK: paper — an italic initial in coloured ink

    private var initial: some View {
        Text(claude ? "C" : "X")
            .font(.system(size: size * 1.35, weight: isLight ? .regular : .heavy, design: .serif).italic())
            .foregroundStyle(ink)
            .strikethrough(state == .done, color: ink)
            .fixedSize()
            .frame(width: size, height: size)
    }

    // MARK: midnight — issue-status rings in the Linear manner

    private func linearStatus(t: Double) -> some View {
        let line = max(1, size * 0.14)
        return ZStack {
            switch state {
            case .working:
                // A ring with a pie that fills as it turns; Codex runs its ring as a hexagon.
                outline.stroke(ink, lineWidth: line)
                Circle().trim(from: 0, to: 0.25 + 0.5 * (0.5 + 0.5 * sin(t * 2)))
                    .stroke(ink, style: StrokeStyle(lineWidth: size * 0.26))
                    .frame(width: size * 0.42, height: size * 0.42).rotationEffect(.degrees(-90))
            case .waiting:
                outline.stroke(ink, style: StrokeStyle(lineWidth: line, dash: [size * 0.2, size * 0.14]))
                    .rotationEffect(.degrees(t * 90))
            case .error:
                outline.fill(ink)
                Text("!").font(.system(size: size * 0.75, weight: .black)).foregroundStyle(.black)
            case .done:
                outline.fill(ink)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .black)).foregroundStyle(.black.opacity(0.7))
            }
            if isLight && state != .waiting { outline.stroke(Color.black.opacity(0.5), lineWidth: 0.5).padding(line) }
        }
    }

    private var outline: AnyShape { claude ? AnyShape(Circle()) : AnyShape(Hexagon()) }

    // MARK: console — an LED behind a machined bezel

    private var led: some View {
        let lit = state != .done
        let bezel = claude ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.12))
        return ZStack {
            bezel.fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.95)], startPoint: .top, endPoint: .bottom))
            bezel.fill(Color(white: 0.15)).padding(size * 0.14)
            bezel.fill(lit ? ink : Color(white: 0.3)).padding(size * (isLight ? 0.3 : 0.2))
                .shadow(color: lit ? ink : .clear, radius: size * 0.35)
            Circle().fill(.white.opacity(lit ? 0.7 : 0.2)).frame(width: size * 0.18).offset(x: -size * 0.1, y: -size * 0.1)
        }
    }

    // MARK: phosphor — a text-mode spinner, one glyph per state

    private func spinner(t: Double) -> some View {
        let frames = claude ? ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] : ["|", "/", "–", "\\"]
        let glyph: String = switch state {
        case .working: frames[Int(t * (claude ? 10 : 6)) % frames.count]
        case .waiting: Int(t * 2) % 2 == 0 ? "?" : " "
        case .error: "!"
        case .done: isLight ? "·" : "•"
        }
        return Text(glyph)
            .font(.system(size: size * 1.4, weight: isLight ? .regular : .bold, design: .monospaced))
            .foregroundStyle(ink)
            .shadow(color: ink.opacity(0.8), radius: 2)
            .fixedSize()
            .frame(width: size, height: size)
    }

    // MARK: synthwave — a glowing neon tube

    private var neon: some View {
        let shape = claude ? AnyShape(Triangle()) : AnyShape(Diamond())
        return ZStack {
            shape.stroke(ink, lineWidth: isLight ? 1 : max(1.4, size * 0.2)).blur(radius: 1.5).opacity(0.9)
            shape.stroke(Color.white.opacity(state == .done ? 0.3 : 0.9), lineWidth: isLight ? 0.6 : 0.9)
        }
        .shadow(color: ink, radius: size * 0.4)
        .padding(-size * 0.05)
    }

    // MARK: blueprint — a drafting symbol

    private var drafting: some View {
        let line: CGFloat = 0.9
        let dash: [CGFloat] = isLight ? [1.5, 1.2] : []
        return ZStack {
            if claude {
                Circle().stroke(ink, style: StrokeStyle(lineWidth: line, dash: dash))
                Path { p in
                    p.move(to: CGPoint(x: -size * 0.15, y: size / 2)); p.addLine(to: CGPoint(x: size * 1.15, y: size / 2))
                    p.move(to: CGPoint(x: size / 2, y: -size * 0.15)); p.addLine(to: CGPoint(x: size / 2, y: size * 1.15))
                }.stroke(ink.opacity(0.7), lineWidth: 0.5)
            } else {
                Rectangle().stroke(ink, style: StrokeStyle(lineWidth: line, dash: dash))
                Path { p in
                    p.move(to: .zero); p.addLine(to: CGPoint(x: size, y: size))
                    p.move(to: CGPoint(x: size, y: 0)); p.addLine(to: CGPoint(x: 0, y: size))
                }.stroke(ink.opacity(0.7), lineWidth: 0.5)
            }
            if state != .done { Circle().fill(ink).frame(width: size * 0.3) }
        }
    }

    // MARK: brutal — a chunky sticker on a hard shadow

    private var sticker: some View {
        let shape = claude ? AnyShape(Starburst()) : AnyShape(RoundedRectangle(cornerRadius: 1.5))
        let fill: Color = switch state {
        case .working: Color(red: 0.35, green: 0.9, blue: 0.5)
        case .waiting: Color(red: 1, green: 0.45, blue: 0.72)
        case .error: Color(red: 1, green: 0.3, blue: 0.25)
        case .done: Color(white: 0.85)
        }
        return ZStack {
            shape.fill(Color.black).offset(x: 1.3, y: 1.3)
            shape.fill(isLight ? Color.white : fill)
            shape.stroke(Color.black, lineWidth: 1.2)
            if isLight { shape.fill(fill).padding(size * 0.3) }
        }
    }

    // MARK: hologram — an iridescent prism that turns while working

    private func prism(t: Double) -> some View {
        let shape = claude ? AnyShape(Circle()) : AnyShape(Hexagon())
        let spin = state == .working ? t * 120 : 0
        return ZStack {
            shape.stroke(AngularGradient(colors: Theme.holoColors, center: .center, angle: .degrees(spin)), lineWidth: isLight ? 1 : size * 0.26)
            Circle().fill(ink).frame(width: size * 0.34).shadow(color: ink, radius: 2)
        }
        .saturation(state == .done ? 0 : 1)
    }

    // MARK: wasteland — 5×5 pixel glyphs on a green terminal

    private func pixels(t: Double) -> some View {
        let rows: [String] = switch state {
        case .working where claude: Int(t * 3) % 2 == 0 ? ["..#..", ".###.", "#####", ".###.", "..#.."] : ["#.#.#", ".###.", "#####", ".###.", "#.#.#"]
        case .working: Int(t * 3) % 2 == 0 ? ["#####", "#...#", "#.#.#", "#...#", "#####"] : ["#####", "##.##", "#...#", "##.##", "#####"]
        case .waiting: Int(t * 2) % 2 == 0 ? [".###.", "#...#", "..##.", ".....", "..#.."] : [".....", ".....", ".....", ".....", "....."]
        case .error: ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]
        case .done: claude ? [".....", ".###.", ".#.#.", ".###.", "....."] : [".....", ".###.", ".###.", ".###.", "....."]
        }
        return Canvas { ctx, sz in
            let cell = sz.width / 5
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    let r = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell * 0.86, height: cell * 0.86)
                    ctx.fill(Path(r), with: .color(ink.opacity(isLight && (x + y) % 2 == 1 ? 0.45 : 1)))
                }
            }
        }
        .shadow(color: ink.opacity(0.8), radius: 1.5)
        .frame(width: size, height: size)
    }
}

extension ThemeMark {
    // MARK: pixel — a tiny game sprite: a heart for Claude, a gem for Codex

    func sprite(t: Double) -> some View {
        PixelSprite(vendor: vendor, state: state, isLight: isLight, size: size,
                    hop: state == .working && Int(t * 4) % 2 == 0).equatable()
    }
}

extension ThemeMark {
    // MARK: ducks — a rubber duck: Claude swims right, Codex swims left in dark shades

    func duck(t: Double) -> some View {
        let body: Color = switch state {
        // A working Codex duck is blue, so the two vendors part even at the smallest size; alarms look the same for both.
        case .working: claude ? Color(red: 1, green: 0.84, blue: 0.1) : Color(red: 0.3, green: 0.68, blue: 1)
        case .waiting: Color(red: 1, green: 0.55, blue: 0.1)
        case .error: Color(red: 0.95, green: 0.32, blue: 0.3)
        case .done: Color(red: 0.72, green: 0.77, blue: 0.82)
        }
        let beak = state == .waiting ? Color(red: 0.85, green: 0.22, blue: 0.05) : Color(red: 1, green: 0.48, blue: 0.05)
        let line = Color(red: 0.32, green: 0.18, blue: 0.04)
        // Working ducks bob on the water; a waiting duck quacks with its beak open; an error capsizes it; done sleeps.
        let bob = state == .working ? CGFloat(sin(t * 5)) : 0
        let side = size
        return Canvas { ctx, sz in
            // The outline is drawn outside each part, so the duck sits inside the box by its width.
            let w = max(0.6, sz.width * 0.07)
            ctx.translateBy(x: w, y: w)
            let s = sz.width - 2 * w
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let parts = [
                Path(ellipseIn: CGRect(x: 0.04 * s, y: 0.5 * s, width: 0.8 * s, height: 0.42 * s)),
                Path { p in p.move(to: pt(0.06, 0.64)); p.addLine(to: pt(0.02, 0.42)); p.addLine(to: pt(0.26, 0.56)); p.closeSubpath() },
                Path(ellipseIn: CGRect(x: 0.42 * s, y: 0.14 * s, width: 0.42 * s, height: 0.42 * s)),
            ]
            let beaks: [Path] = state == .waiting
                ? [Path { p in p.move(to: pt(0.8, 0.3)); p.addLine(to: pt(0.96, 0.28)); p.addLine(to: pt(0.82, 0.39)); p.closeSubpath() },
                   Path { p in p.move(to: pt(0.82, 0.42)); p.addLine(to: pt(0.95, 0.5)); p.addLine(to: pt(0.8, 0.47)); p.closeSubpath() }]
                : [Path { p in p.move(to: pt(0.8, 0.31)); p.addLine(to: pt(1, 0.39)); p.addLine(to: pt(0.8, 0.46)); p.closeSubpath() }]
            // Outline every part first, then fill over it: the inner seams disappear and only the silhouette keeps a line.
            for part in parts + beaks { ctx.stroke(part, with: .color(isLight ? body : line), lineWidth: w * 2) }
            for part in parts { ctx.fill(part, with: .color(isLight ? .white : body)) }
            for part in beaks { ctx.fill(part, with: .color(beak)) }
            let eye = pt(0.68, 0.3)
            if !claude {
                // Codex is the hacker duck: dark shades with a strap, worn even asleep.
                let shades = Path(roundedRect: CGRect(x: 0.54 * s, y: 0.23 * s, width: 0.3 * s, height: 0.14 * s), cornerRadius: 0.05 * s)
                ctx.stroke(Path { p in p.move(to: pt(0.44, 0.27)); p.addLine(to: pt(0.56, 0.27)) }, with: .color(.black), lineWidth: max(0.6, s * 0.05))
                ctx.fill(shades, with: .color(.black))
                ctx.fill(Path(CGRect(x: 0.6 * s, y: 0.25 * s, width: max(0.6, 0.07 * s), height: max(0.6, 0.035 * s))), with: .color(.white.opacity(0.85)))
            } else if state == .done {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: eye.x - s * 0.06, y: eye.y)); p.addLine(to: CGPoint(x: eye.x + s * 0.05, y: eye.y)) },
                           with: .color(line), lineWidth: max(0.8, s * 0.06))
            } else {
                let r = max(0.8, s * 0.055)
                ctx.fill(Path(ellipseIn: CGRect(x: eye.x - r, y: eye.y - r, width: r * 2, height: r * 2)), with: .color(line))
            }
        }
        .frame(width: side, height: side)
        // A capsized duck flips belly-up but keeps facing its own way.
        .scaleEffect(x: claude ? 1 : -1, y: state == .error ? -1 : 1)
        .rotationEffect(.degrees(Double(bob) * 7))
        .offset(y: bob * side * 0.07)
    }
}

/// A vendor mark outside a row (summary counts, project headers): the theme's mark, or the chosen style in «Терминал».
struct ThemedVendorMark: View {
    let vendor: Vendor
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        ResolvedVendorMark(vendor: vendor, state: .working, isLight: false, size: settings.appearance.markSize.points)
    }
}

struct Hexagon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 0..<6 {
            let a = Double(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: r.midX + r.width / 2 * CGFloat(cos(a)), y: r.midY + r.height / 2 * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.06))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.06))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - r.height * 0.06))
            p.closeSubpath()
        }
    }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath()
        }
    }
}

struct Starburst: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = 8
        for i in 0..<(n * 2) {
            let a = Double(i) * .pi / Double(n) - .pi / 2
            let rad = (i % 2 == 0 ? 0.5 : 0.32) * r.width
            let pt = CGPoint(x: r.midX + rad * CGFloat(cos(a)), y: r.midY + rad * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
