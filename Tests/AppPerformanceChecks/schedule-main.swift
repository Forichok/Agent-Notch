import AppKit
import SwiftUI

@main struct SchedulePerformanceChecks {
    @MainActor static func main() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for interval in [0.12, 0.25, 0.5, 1, 60] {
            for mode in [TimelineScheduleMode.normal, .lowFrequency] {
                let paused = Array(SurfaceSchedule(interval: interval, active: false).entries(from: start, mode: mode).prefix(10))
                guard paused == [start] else { print("FAIL hidden surface keeps ticking"); exit(1) }
                let resumed = Array(SurfaceSchedule(interval: interval, active: true).entries(from: start, mode: mode).prefix(3))
                // The mount draws at once, then ticks land on shared multiples of the interval.
                let boundary = ((start.timeIntervalSinceReferenceDate / interval).rounded(.down) + 1) * interval
                let expected = [start, Date(timeIntervalSinceReferenceDate: boundary), Date(timeIntervalSinceReferenceDate: boundary + interval)]
                guard resumed.count == expected.count, zip(resumed, expected).allSatisfy({ abs($0.timeIntervalSince($1)) < 0.000001 }) else { print("FAIL visible cadence changed: \(interval)"); exit(1) }
            }
        }
        checkAlignedPhase()
        checkMountedReactivation()
        print("OK hidden schedules stop and mounted timelines resume without resetting state")
    }
    /// Marks mounted at different moments must tick together, or each one wakes the window on its own.
    static func checkAlignedPhase() {
        for interval in [0.12, 0.25, 0.5, 1] {
            let a = Array(SurfaceSchedule(interval: interval, active: true).entries(from: Date(timeIntervalSinceReferenceDate: 1_000.013), mode: .normal).prefix(4))
            let b = Array(SurfaceSchedule(interval: interval, active: true).entries(from: Date(timeIntervalSinceReferenceDate: 1_000.071), mode: .normal).prefix(4))
            guard a.count == 4, b.count == 4, a[2] == b[2], a[3] == b[3], abs(a[3].timeIntervalSince(a[2]) - interval) < 0.000001 else {
                print("FAIL timelines mounted apart tick on their own phase: \(interval)"); exit(1)
            }
        }
    }
    @MainActor static func checkMountedReactivation() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let activity = SurfaceActivity()
        let frames = Frames()
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 64, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ActiveSurface(activity: activity) { MountedProbe(frames: frames) })
        window.orderFrontRegardless()
        func settle(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        settle(0.3)
        let initiallyPaused = frames.dates.count
        settle(0.3)
        guard frames.dates.count == initiallyPaused else { print("FAIL initially hidden surface ticks"); exit(1) }
        activity.setActive(true)
        settle(0.6)
        guard frames.dates.count >= initiallyPaused + 2 else { print("FAIL mounted timeline did not start"); exit(1) }
        activity.setActive(false)
        settle(0.2)
        let paused = frames.dates.count
        settle(0.4)
        guard frames.dates.count == paused else { print("FAIL hidden mounted timeline keeps ticking"); exit(1) }
        activity.setActive(true)
        settle(0.6)
        guard frames.dates.count >= paused + 2, frames.identities.count == 1 else {
            print("FAIL reopening did not resume the same mounted state"); exit(1)
        }
        window.close()
    }
}

@MainActor private final class Frames {
    var dates = Set<Date>()
    var identities = Set<UUID>()
    func record(_ date: Date, identity: UUID) {
        dates.insert(date); identities.insert(identity)
    }
}

private struct MountedProbe: View {
    let frames: Frames
    @State private var identity = UUID()
    var body: some View {
        SurfaceTimeline(every: 0.05) { date in
            let _ = frames.record(date, identity: identity)
            Color.clear.frame(width: 32, height: 32)
        }
    }
}
