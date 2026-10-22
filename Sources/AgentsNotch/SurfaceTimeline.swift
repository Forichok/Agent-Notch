import SwiftUI

extension EnvironmentValues {
    @Entry var surfaceActive = true
}

/// Keep a hidden panel mounted without leaving its periodic updates running.
@MainActor
final class SurfaceActivity: ObservableObject {
    @Published private(set) var active = false

    func setActive(_ value: Bool) {
        if active != value { active = value }
    }
}

struct ActiveSurface<Content: View>: View {
    @ObservedObject var activity: SurfaceActivity
    let content: Content

    init(activity: SurfaceActivity, @ViewBuilder content: () -> Content) {
        self.activity = activity
        self.content = content()
    }

    var body: some View {
        content.environment(\.surfaceActive, activity.active)
    }
}

/// A paused schedule supplies one frame; its content keeps the same view identity.
/// Ticks fall on whole multiples of the interval, so every mark on a surface redraws in the same frame
/// instead of each one waking the window on its own phase.
struct SurfaceSchedule: TimelineSchedule {
    let interval: TimeInterval
    let active: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if active {
            let step = interval
            let state: (first: Date?, tick: Double) = (startDate, (startDate.timeIntervalSinceReferenceDate / step).rounded(.down))
            return AnySequence(sequence(state: state) { s -> Date? in
                if let first = s.first { s.first = nil; return first }
                s.tick += 1
                return Date(timeIntervalSinceReferenceDate: s.tick * step)
            })
        }
        return AnySequence([startDate])
    }
}

struct SurfaceTimeline<Content: View>: View {
    let interval: TimeInterval
    let content: (Date) -> Content
    @Environment(\.surfaceActive) private var active

    init(every interval: TimeInterval, @ViewBuilder content: @escaping (Date) -> Content) {
        self.interval = interval
        self.content = content
    }

    var body: some View {
        TimelineView(SurfaceSchedule(interval: interval, active: active)) { context in
            content(context.date)
        }
    }
}
